import Foundation
import Network

extension Notification.Name {
    static let artworkConnectivityRecovered = Notification.Name("artworkConnectivityRecovered")
}

private final class ArtworkConnectivityMonitor: @unchecked Sendable {
    static let shared = ArtworkConnectivityMonitor()
    private let queue = DispatchQueue(label: "ArtworkConnectivityMonitor")
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var started = false
    private var wasAvailable = false

    func startIfNeeded() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let available = path.status == .satisfied && !path.isConstrained
            self.lock.lock()
            let recovered = available && !self.wasAvailable
            self.wasAvailable = available
            self.lock.unlock()
            if recovered {
                NotificationCenter.default.post(name: .artworkConnectivityRecovered, object: nil)
            }
        }
        monitor.start(queue: queue)
    }
}

enum ArtworkLoadFailure: Equatable, Sendable {
    case offline
    case transport
    case server(statusCode: Int, retryAfter: TimeInterval?)
    case authentication
    case permanentHTTP
    case invalidContent
    case cancelled
}

/// Pure retry decisions shared by visible covers and the active player.
enum ArtworkRetryPolicy {
    static let minimumConnectivityGap: TimeInterval = 12
    static let maximumRetryAfter: TimeInterval = 60 * 60

    static func delay(
        after failure: ArtworkLoadFailure,
        attempt: Int,
        jitter: Double = 0
    ) -> TimeInterval? {
        guard attempt > 0 else { return nil }
        switch failure {
        case .cancelled, .authentication, .permanentHTTP:
            return nil
        case .server(let statusCode, let retryAfter) where statusCode == 429 || statusCode == 503:
            let normal = transientDelay(attempt: attempt, jitter: jitter)
            guard let retryAfter else { return normal }
            return max(normal, min(max(retryAfter, minimumConnectivityGap), maximumRetryAfter))
        case .invalidContent:
            return maximumRetryAfter
        case .offline, .transport, .server:
            return transientDelay(attempt: attempt, jitter: jitter)
        }
    }

    static func transientDelay(attempt: Int, jitter: Double = 0) -> TimeInterval {
        let schedule: [TimeInterval] = [15, 60, 5 * 60, 15 * 60]
        let base = attempt <= schedule.count ? schedule[attempt - 1] : 60 * 60
        // Jitter is injected, bounded to ±10%, and deterministic in tests.
        return max(1, base * (1 + min(max(jitter, -1), 1) * 0.1))
    }

    static func shouldRetryOnConnectivityRecovery(
        failure: ArtworkLoadFailure,
        elapsedSinceAttempt: TimeInterval,
        retryAfterRemaining: TimeInterval = 0
    ) -> Bool {
        guard elapsedSinceAttempt >= minimumConnectivityGap,
              retryAfterRemaining <= 0 else { return false }
        switch failure {
        case .offline, .transport, .server, .invalidContent:
            return true
        case .authentication, .permanentHTTP, .cancelled:
            return false
        }
    }
}

/// Serializes recovery state by source plus credential profile. It stores only
/// retry metadata; decoded images remain in SharedImageRepository.
actor ArtworkRecoveryCoordinator {
    static let shared = ArtworkRecoveryCoordinator()

    protocol Clock: Sendable {
        func now() -> TimeInterval
    }

    private struct SystemClock: Clock {
        private let clock = ContinuousClock()
        private let origin = ContinuousClock().now

        func now() -> TimeInterval {
            let value = origin.duration(to: clock.now).components
            return TimeInterval(value.seconds) + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
        }
    }

    struct Snapshot: Sendable, Equatable {
        let attempts: Int
        let nextRetryAt: TimeInterval?
        let lastFailure: ArtworkLoadFailure?
    }

    private struct State {
        var attempts = 0
        var lastAttempt: TimeInterval?
        var nextRetryAt: TimeInterval?
        var failure: ArtworkLoadFailure?
    }

    private struct InFlight {
        let id: UUID
        let task: Task<ImageDataLoadResult, Never>
    }

    private let clock: any Clock
    private let jitter: @Sendable () -> Double
    private var states: [String: State] = [:]
    private var inFlight: [String: InFlight] = [:]

    init(
        clock: any Clock = SystemClock(),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: -1...1) }
    ) {
        self.clock = clock
        self.jitter = jitter
    }

    func snapshot(for key: String) -> Snapshot {
        let state = states[key] ?? State()
        return Snapshot(attempts: state.attempts, nextRetryAt: state.nextRetryAt, lastFailure: state.failure)
    }

    func retryDelayRemaining(for key: String) -> TimeInterval? {
        guard let state = states[key], let due = state.nextRetryAt else { return nil }
        return max(0, due - clock.now())
    }

    func shouldRetryAfterConnectivityRecovery(_ key: String) -> Bool {
        connectivityRecovered().contains(key)
    }

    func mayAttempt(_ key: String, explicit: Bool = false) -> Bool {
        guard let state = states[key] else { return true }
        guard explicit == false else { return state.failure != .cancelled }
        guard state.failure != .authentication, state.failure != .permanentHTTP else { return false }
        guard let due = state.nextRetryAt else { return true }
        return clock.now() >= due
    }

    func load(
        key: String,
        explicit: Bool = false,
        operation: @escaping @Sendable () async -> ImageDataLoadResult
    ) async -> ImageDataLoadResult {
        ArtworkConnectivityMonitor.shared.startIfNeeded()
        if let existing = inFlight[key] { return await existing.task.value }
        guard mayAttempt(key, explicit: explicit) else { return .deferred }

        var state = states[key] ?? State()
        state.lastAttempt = clock.now()
        states[key] = state
        let flightID = UUID()
        let task = Task(priority: .userInitiated, operation: operation)
        inFlight[key] = InFlight(id: flightID, task: task)
        let result = await task.value
        guard inFlight[key]?.id == flightID,
              Task.isCancelled == false,
              task.isCancelled == false else { return .failure(.cancelled) }
        inFlight[key] = nil

        switch result {
        case .success:
            states[key] = nil
        case .failure(let failure):
            if failure == .cancelled { return result }
            state.attempts += 1
            state.failure = failure
            if let seconds = ArtworkRetryPolicy.delay(after: failure, attempt: state.attempts, jitter: jitter()) {
                state.nextRetryAt = clock.now() + seconds
            } else {
                state.nextRetryAt = nil
            }
            states[key] = state
        case .deferred:
            break
        }
        return result
    }

    func connectivityRecovered() -> [String] {
        let now = clock.now()
        return states.compactMap { key, state in
            guard let lastAttempt = state.lastAttempt,
                  let failure = state.failure else { return nil }
            let elapsed = now - lastAttempt
            let retryRemaining = state.nextRetryAt.map { $0 - now } ?? 0
            return ArtworkRetryPolicy.shouldRetryOnConnectivityRecovery(
                failure: failure,
                elapsedSinceAttempt: elapsed,
                retryAfterRemaining: max(0, retryRemaining)
            ) ? key : nil
        }
    }

    func cancel(_ key: String) {
        inFlight[key]?.task.cancel()
        inFlight[key] = nil
        states[key] = nil
    }

    func recordFailure(_ key: String, failure: ArtworkLoadFailure) {
        guard failure != .cancelled else { return }
        var state = states[key] ?? State()
        state.attempts += 1
        state.lastAttempt = clock.now()
        state.failure = failure
        if let seconds = ArtworkRetryPolicy.delay(after: failure, attempt: state.attempts, jitter: jitter()) {
            state.nextRetryAt = clock.now() + seconds
        } else {
            state.nextRetryAt = nil
        }
        states[key] = state
    }

    func resetAuthenticationFailures(profileID: String?) {
        let suffix = "|profile:\(profileID ?? "public")"
        for key in Array(states.keys) where key.hasSuffix(suffix) && states[key]?.failure == .authentication {
            states[key] = nil
        }
    }
}
