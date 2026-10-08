import Combine
import Foundation
import SwiftData

/// Stage A contains only immutable inputs and network/parser work. Its output
/// carries a typed parsed feed to the model actor; no SwiftData model or raw
/// `[String: Any]` dictionary crosses this boundary.
enum PodcastRefreshNetworkPreparer {
    struct Endpoint: Sendable {
        let url: URL
        let firstPage: PreparedPodcastFeedSeed?
    }

    enum Outcome: Sendable {
        case complete(PreparedPodcastFeed)
        case partial(PreparedPodcastFeed)

        var feed: PreparedPodcastFeed {
            switch self {
            case .complete(let feed), .partial(let feed): feed
            }
        }

        var isPartial: Bool {
            if case .partial = self { return true }
            return false
        }
    }

    static func resolveEndpoint(
        from url: URL,
        profile: PodcastAccessProfile?,
        knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers,
        client: PodcastHTTPClient
    ) async throws -> Endpoint {
        let resolved = try await PodcastFeedResolver.resolvePreparedExistingEndpoint(
            from: url,
            profile: profile,
            knownEpisodeIdentifiers: knownEpisodeIdentifiers,
            client: client
        )
        return Endpoint(url: resolved.url, firstPage: resolved.firstPage)
    }

    static func preparePages(
        from url: URL,
        knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers,
        profile: PodcastAccessProfile?,
        firstPage: PreparedPodcastFeedSeed?,
        startingAt: URL?,
        client: PodcastHTTPClient
    ) async throws -> Outcome {
        let feed = try await PodcastParser.prepareAllPages(
            from: url,
            knownEpisodeIdentifiers: knownEpisodeIdentifiers,
            profile: profile,
            firstPage: firstPage,
            startingAt: startingAt,
            client: client
        )
        return feed.isPartial ? .partial(feed) : .complete(feed)
    }
}

/// Serializes destructive and refresh writes for one feed while allowing
/// unrelated podcasts to continue independently.
actor PodcastMutationCoordinator {
    static let shared = PodcastMutationCoordinator()

    private var activeKeys = Set<String>()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waiters: [String: [Waiter]] = [:]

    func withExclusive<T: Sendable>(
        feedURL: URL,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let key = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        try await acquire(key)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(key)
            return result
        } catch {
            release(key)
            throw error
        }
    }

    private func acquire(_ key: String) async throws {
        try Task.checkCancellation()
        if activeKeys.insert(key).inserted { return }
        let waiterID = UUID()
        let _: Void = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // The holder may release while this task suspends to install
                // its cancellation handler. Recheck ownership atomically on
                // the actor before appending a waiter.
                if activeKeys.insert(key).inserted {
                    continuation.resume(returning: ())
                    return
                }
                waiters[key, default: []].append(
                    Waiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(key, id: waiterID) }
        }
    }

    private func cancelWaiter(_ key: String, id: UUID) {
        guard var queued = waiters[key],
              let index = queued.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queued.remove(at: index)
        waiters[key] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: String) {
        if var queued = waiters[key], queued.isEmpty == false {
            let next = queued.removeFirst()
            waiters[key] = queued.isEmpty ? nil : queued
            next.continuation.resume(returning: ())
        } else {
            activeKeys.remove(key)
        }
    }
}

/// One writer gate for feed-to-episode graph imports. It prevents model actors
/// from interleaving relationship mutations and saves in shared SwiftData stores.
actor PodcastFeedCommitCoordinator {
    static let shared = PodcastFeedCommitCoordinator()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var occupied = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if occupied == false {
            occupied = true
            return
        }
        let waiterID = UUID()
        let _: Void = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if occupied == false {
                    occupied = true
                    continuation.resume(returning: ())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().continuation.resume(returning: ())
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Shares one refresh result with callers whose requested work is satisfied by
/// the active request. A stronger request waits and then starts its own pass;
/// a HEAD-only result cannot complete a manual GET request. Waiters own their
/// interest independently, so cancellation of one caller does not stop a run
/// that another caller still needs.
actor FeedRefreshCoordinator {
    static let shared = FeedRefreshCoordinator()
    private struct FlightChanged: Error {}

    struct Intent: Sendable {
        let requiresGET: Bool
        let visible: Bool
        let resolvesMissingDurations: Bool
        let processesNewEpisodes: Bool
        let deadline: Date?

        func satisfies(_ requested: Intent) -> Bool {
            (!requested.requiresGET || requiresGET)
                && (!requested.visible || visible)
                && (!requested.resolvesMissingDurations || resolvesMissingDurations)
                && (!requested.processesNewEpisodes || processesNewEpisodes)
                && (deadline == nil || requested.deadline != nil && deadline! >= requested.deadline!)
        }
    }

    private struct Flight {
        let id: UUID
        let intent: Intent
        let task: Task<Void, Never>
        var resultWaiters: [UUID: CheckedContinuation<PodcastUpdateSummary, any Error>]
        var completionWaiters: [UUID: CheckedContinuation<Void, any Error>]
        var progressObservers: [UUID: SubscriptionProgressHandler]
        var latestProgress: SubscriptionProgressUpdate?
    }

    private var flights: [String: Flight] = [:]

    func run(
        feedURL: URL,
        profileScope: String? = nil,
        intent: Intent,
        operation: @escaping @Sendable () async throws -> PodcastUpdateSummary
    ) async throws -> PodcastUpdateSummary {
        try await run(feedURL: feedURL, profileScope: profileScope, intent: intent, progress: nil) { _ in
            try await operation()
        }
    }

    func run(
        feedURL: URL,
        profileScope: String? = nil,
        intent: Intent,
        progress: SubscriptionProgressHandler?,
        operation: @escaping @Sendable (SubscriptionProgressHandler?) async throws -> PodcastUpdateSummary
    ) async throws -> PodcastUpdateSummary {
        // A profile ID separates credentials without placing secrets in logs
        // or coalescing independent access scopes for the same endpoint.
        let key = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
            + "|" + (profileScope ?? "public")
        while true {
            try Task.checkCancellation()
            if let flight = flights[key] {
                let waiterID = UUID()
                if flight.intent.satisfies(intent) {
                    do {
                        let result: PodcastUpdateSummary = try await withTaskCancellationHandler {
                            try await withCheckedThrowingContinuation { continuation in
                                guard var current = flights[key], current.id == flight.id else {
                                    continuation.resume(throwing: FlightChanged())
                                    return
                                }
                                current.resultWaiters[waiterID] = continuation
                                if let progress {
                                    current.progressObservers[waiterID] = progress
                                    if let latest = current.latestProgress {
                                        Task { await progress(latest) }
                                    }
                                }
                                flights[key] = current
                            }
                        } onCancel: {
                            Task { await self.cancelWaiter(key: key, flightID: flight.id, waiterID: waiterID) }
                        }
                        try Task.checkCancellation()
                        return result
                    } catch is FlightChanged {
                        continue
                    }
                }
                do {
                    let _: Void = try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                            guard var current = flights[key], current.id == flight.id else {
                                continuation.resume(throwing: FlightChanged())
                                return
                            }
                            current.completionWaiters[waiterID] = continuation
                            flights[key] = current
                        }
                    } onCancel: {
                        Task { await self.cancelWaiter(key: key, flightID: flight.id, waiterID: waiterID) }
                    }
                } catch is FlightChanged {
                    continue
                }
                continue
            }

            let flightID = UUID()
            let task = Task {
                let result: Result<PodcastUpdateSummary, any Error>
                do {
                    let broadcaster: SubscriptionProgressHandler = { update in
                        await self.publish(update, key: key, flightID: flightID)
                    }
                    result = .success(try await operation(broadcaster))
                } catch {
                    result = .failure(error)
                }
                self.complete(key: key, flightID: flightID, result: result)
            }
            flights[key] = Flight(
                id: flightID,
                intent: intent,
                task: task,
                resultWaiters: [:],
                completionWaiters: [:],
                progressObservers: [:],
                latestProgress: nil
            )
        }
    }

    private func publish(_ update: SubscriptionProgressUpdate, key: String, flightID: UUID) async {
        guard var flight = flights[key], flight.id == flightID else { return }
        flight.latestProgress = update
        flights[key] = flight
        for observer in flight.progressObservers.values {
            await observer(update)
        }
    }

    private func cancelWaiter(key: String, flightID: UUID, waiterID: UUID) {
        guard var flight = flights[key], flight.id == flightID else { return }
        if let waiter = flight.resultWaiters.removeValue(forKey: waiterID) {
            waiter.resume(throwing: CancellationError())
        }
        if let waiter = flight.completionWaiters.removeValue(forKey: waiterID) {
            waiter.resume(throwing: CancellationError())
        }
        flight.progressObservers[waiterID] = nil
        if flight.resultWaiters.isEmpty && flight.completionWaiters.isEmpty {
            flight.task.cancel()
        }
        flights[key] = flight
    }

    private func complete(
        key: String,
        flightID: UUID,
        result: Result<PodcastUpdateSummary, any Error>
    ) {
        guard let flight = flights[key], flight.id == flightID else { return }
        flights[key] = nil
        for waiter in flight.resultWaiters.values {
            waiter.resume(with: result)
        }
        for waiter in flight.completionWaiters.values {
            waiter.resume(returning: ())
        }
    }
}

/// Snapshot of a "refresh all podcasts" run, as the UI needs to draw it.
struct PodcastRefreshProgress: Sendable, Equatable {
    var isRefreshing: Bool = false
    var completed: Int = 0
    var total: Int = 0
    var lastFetchDate: Date?
    var errorMessage: String?

    static let idle = PodcastRefreshProgress()
}

/// Shared state of a user-initiated "refresh all podcasts" run.
///
/// The library and the inbox both offer a refresh button, and both used to own a
/// private view model. A refresh started in the library therefore left the inbox
/// looking idle even though feeds were being fetched. Both screens now observe
/// this one coordinator, so whichever screen starts the run, every screen shows
/// the same progress and the same disabled button.
///
/// The coordinator itself has no actor isolation: feed workers report progress
/// from whatever executor they happen to run on, and a lock keeps the snapshot
/// consistent. Announcements reach the UI through ``progressPublisher``, which
/// hops to the main queue for its subscribers, so the refresh never has to hop
/// to the main actor just to record a number.
final class PodcastRefreshCoordinator: @unchecked Sendable {
    static let shared = PodcastRefreshCoordinator()

    private let lock = NSLock()
    private let subject = CurrentValueSubject<PodcastRefreshProgress, Never>(.idle)
    private var activeRefresh: Task<Void, Never>?

    /// Announces every change to the snapshot, on the main queue.
    ///
    /// Stored rather than computed: a fresh `AnyPublisher` per body evaluation
    /// makes SwiftUI tear the subscription down and build it up again on every
    /// redraw.
    let progressPublisher: AnyPublisher<PodcastRefreshProgress, Never>

    private init() {
        progressPublisher = subject
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// The latest snapshot, for a view that needs a value before its first
    /// publisher delivery.
    var progress: PodcastRefreshProgress {
        subject.value
    }

    /// Refreshes every subscribed feed, or joins the run that is already going so
    /// a second screen waits for the same work instead of starting a duplicate pass.
    func refreshAllPodcasts(modelContainer: ModelContainer) async {
        await startOrJoinRefresh(modelContainer: modelContainer).value
    }

    /// Synchronous so the whole decision — join or start, and announce the start —
    /// happens in one critical section. `NSLock` is off limits in an async context.
    private func startOrJoinRefresh(modelContainer: ModelContainer) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }

        if let activeRefresh {
            return activeRefresh
        }

        var started = subject.value
        started.isRefreshing = true
        started.completed = 0
        started.total = 0
        started.errorMessage = nil

        let task = Task {
            await self.performRefresh(modelContainer: modelContainer)
        }
        activeRefresh = task
        // Announced inside the lock so the "started" snapshot can never land after
        // a progress update from the task it started.
        subject.send(started)
        return task
    }

    private func performRefresh(modelContainer: ModelContainer) async {
        var errorMessage: String?

        do {
            let actor = PodcastModelActor(modelContainer: modelContainer)
            try await actor.refreshAllPodcasts { [weak self] completed, total in
                self?.report(completed: completed, total: total)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        finish(errorMessage: errorMessage)
    }

    private func report(completed: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }

        var snapshot = subject.value
        guard snapshot.isRefreshing else { return }
        snapshot.completed = completed
        snapshot.total = total
        subject.send(snapshot)
    }

    private func finish(errorMessage: String?) {
        lock.lock()
        defer { lock.unlock() }

        activeRefresh = nil

        var snapshot = subject.value
        snapshot.isRefreshing = false
        snapshot.errorMessage = errorMessage
        if errorMessage == nil {
            snapshot.lastFetchDate = Date()
        }
        subject.send(snapshot)
    }
}
