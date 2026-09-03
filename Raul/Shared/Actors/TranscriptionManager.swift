import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

enum TranscriptionStartOrigin: Sendable {
    case manual
    case automatic
}

struct TranscriptionQueueEntry: Identifiable, Sendable {
    enum QueueState: Sendable {
        case active
        case queued(position: Int)
    }

    let episodeURL: URL
    let episodeTitle: String
    let podcastTitle: String?
    let state: QueueState

    var id: URL { episodeURL }
}

actor TranscriptionTurnQueue {
    private struct Waiter {
        let episodeURL: URL
        let continuation: CheckedContinuation<Void, Never>
    }

    private var activeEpisodeURL: URL?
    private var waiters: [Waiter] = []

    func wait(for episodeURL: URL) async {
        if activeEpisodeURL == nil {
            activeEpisodeURL = episodeURL
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(Waiter(episodeURL: episodeURL, continuation: continuation))
        }
    }

    func finish(_ episodeURL: URL) {
        guard activeEpisodeURL == episodeURL else { return }
        guard waiters.isEmpty == false else {
            activeEpisodeURL = nil
            return
        }

        let next = waiters.removeFirst()
        activeEpisodeURL = next.episodeURL
        next.continuation.resume()
    }

    func promote(_ episodeURL: URL) {
        guard let index = waiters.firstIndex(where: { $0.episodeURL == episodeURL }), index > 0 else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiters.insert(waiter, at: 0)
    }

    func cancel(_ episodeURL: URL) {
        guard let index = waiters.firstIndex(where: { $0.episodeURL == episodeURL }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume()
    }

    func snapshot() -> (active: URL?, queued: [URL]) {
        (activeEpisodeURL, waiters.map(\.episodeURL))
    }
}

actor TranscriptionManager {
    // Immutable singleton initialized once, using the main-actor container.
    static let shared: TranscriptionManager = {
        MainActor.assumeIsolated {
            TranscriptionManager(container: ModelContainerManager.shared.container)
        }
    }()

    // Track jobs by episode URL
    private var items: [URL: TranscriptionItem] = [:]
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var taskOrigins: [URL: TranscriptionStartOrigin] = [:]
    private var episodeSnapshots: [URL: TranscriptionEpisodeSnapshot] = [:]
    private var lastAutomaticSweepAt: Date?
    /// Episodes an automatic attempt could not start, with the time they may be
    /// tried again. Without it a single broken episode swallows every sweep.
    private var automaticRetryBlockedUntil: [URL: Date] = [:]
    private let automaticScanLimit = AutomaticTranscriptionCandidateProvider.defaultLimit
    private let automaticSweepCooldown: TimeInterval = 30
    private let automaticRetryCooldown: TimeInterval = 60 * 60 * 6

    // Serializes the heavy transcription work so at most one Speech analyzer runs at a
    // time. Two concurrent analyzers double the e-core pressure, memory, and the odds of
    // tripping the background CPU monitor.
    private let transcriptionQueue = TranscriptionTurnQueue()

    // Dependency
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func item(for episodeURL: URL) -> TranscriptionItem? {
        items[episodeURL]
    }

    func enqueueTranscription(
        episodeURL: URL,
        origin: TranscriptionStartOrigin = .manual
    ) async -> TranscriptionItem? {
        print("enqueueTranscription")
        if let existingItem = items[episodeURL] {
            return existingItem
        }

        let episodeActor = EpisodeActor(modelContainer: container)
        guard let snapshot = await episodeActor.transcriptionSnapshot(for: episodeURL) else {
            await finish(episodeURL: episodeURL, error: "Missing local file.")
            return nil
        }
        episodeSnapshots[episodeURL] = snapshot

        let uiItem = await MainActor.run { () -> TranscriptionItem in
            let item = TranscriptionItem(episodeURL: episodeURL, sourceURL: snapshot.localFile)
            item.setState(.queued, progress: 0.0, status: "Queued")
            return item
        }

        store(item: uiItem, for: episodeURL)
        await episodeActor.attachTranscriptionItem(uiItem, to: episodeURL)

        if tasks[episodeURL] != nil {
            return uiItem
        }

        // User-requested transcriptions run at userInitiated so the Speech XPC lands on
        // performance cores and finishes quickly (and isn't subject to the background
        // 50%/180s CPU monitor). Automatic ones stay at background priority.
        let jobPriority: TaskPriority = origin == .manual ? .userInitiated : .background

        // Kick off orchestration in a Task, but never carry @Model instances out of EpisodeActor.
        let job = Task(priority: jobPriority) { [weak self] in
            guard let self else { return }

            let startedAt = Date()
            print("episode lang: \(snapshot.language ?? "nil")")

#if canImport(UIKit)
            // Background task is MainActor-only; keep its lifetime there.
            let bgTaskID: UIBackgroundTaskIdentifier = await MainActor.run { () -> UIBackgroundTaskIdentifier in
                guard origin == .manual else { return .invalid }
                return UIApplication.shared.beginBackgroundTask(
                    withName: "Transcription",
                    expirationHandler: {
                        Task {
                            await TranscriptionManager.shared.cancel(episodeURL: episodeURL)
                        }
                    }
                )
            }

            // Make sure we end it on MainActor at the end
            defer {
                Task { @MainActor in
                    if bgTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTaskID)
                    }
                }
            }
#endif

            // Only one transcription runs at a time; others wait here.
            let transcriptionQueue = self.transcriptionQueue
            await transcriptionQueue.wait(for: episodeURL)
            defer { Task { await transcriptionQueue.finish(episodeURL) } }

            do {
                try Task.checkCancellation()
                await MainActor.run {
                    uiItem.setState(.preparingModel, progress: 0.02, status: "Preparing model…")
                }

                let settingsActor = PodcastSettingsModelActor(modelContainer: container)
                let maxSnippetDurationSeconds = await settingsActor.getTranscriptionMaxSnippetDurationSeconds()

                // Build transcriber (pure value types: URL + language string).
                // Manual runs race to completion on performance cores; automatic runs
                // duty-cycle on efficiency cores to stay under the background CPU monitor.
                let transcriber = await AITranscripts(
                    url: snapshot.localFile,
                    language: snapshot.language,
                    maxSnippetDurationSeconds: maxSnippetDurationSeconds,
                    analyzerPriority: origin == .manual ? .userInitiated : .background,
                    throttle: origin == .manual ? .none : .backgroundFriendly,
                    progressHandler: { progress, status in
                        await MainActor.run {
                            let nextState: TranscriptionItem.State
                            if status.localizedCaseInsensitiveContains("download") {
                                nextState = .downloadingModel(progress: progress)
                            } else if status.localizedCaseInsensitiveContains("saving")
                                || status.localizedCaseInsensitiveContains("finalizing") {
                                nextState = .saving
                            } else {
                                nextState = .analyzing
                            }
                            uiItem.setState(nextState, progress: progress, status: status)
                        }
                    }
                )

                // Get VTT text as String? (Sendable)
                let vtt = try await transcriber.transcribeTovTT()

                await MainActor.run {
                    uiItem.setState(.saving, progress: 0.95, status: "Saving transcript…")
                }

                guard let vtt else {
                    throw NSError(
                        domain: "TranscriptionManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "The transcription finished without transcript data."]
                    )
                }

                // Persist the transcript first. Chapter generation is optional enrichment
                // and can involve several on-device language-model calls; keeping it out
                // of this critical path makes the transcript available as soon as it is
                // written instead of leaving the UI stuck at "Saving transcript…".
                await MainActor.run {
                    uiItem.setState(.saving, progress: 0.96, status: "Writing transcript…")
                }
                let transcriptSnapshots = try await episodeActor.decodeAndSetTranscript(
                    for: episodeURL,
                    vtt: vtt
                )
                let finishedAt = Date()
                await MainActor.run {
                    uiItem.setState(.saving, progress: 0.98, status: "Saving transcription history…")
                }
                await episodeActor.saveTranscriptionRecord(
                    for: snapshot,
                    localeIdentifier: transcriber.language.identifier(.bcp47),
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    transcriptSnapshots: transcriptSnapshots
                )

                await MainActor.run {
                    uiItem.setState(.finished, progress: 1.0, status: "Finished")
                }

                // Generate chapters after the transcript has been committed. This keeps
                // chapter enrichment from delaying the user's newly saved transcript.
                Task(priority: .utility) {
                    await episodeActor.finalizeTranscriptChapters(for: episodeURL)
                }
                await self.cleanUp(episodeURL: episodeURL)
            } catch is CancellationError {
                await MainActor.run {
                    uiItem.setState(.cancelled, status: "Cancelled")
                }
                await self.cleanUp(episodeURL: episodeURL)
            } catch {
                await self.finish(episodeURL: episodeURL, error: error.localizedDescription)
            }
        }

        // Register the task in actor state
        tasks[episodeURL] = job
        taskOrigins[episodeURL] = origin
        return uiItem
    }

    func cancel(episodeURL: URL) async {
        tasks[episodeURL]?.cancel()
        await transcriptionQueue.cancel(episodeURL)
        tasks[episodeURL] = nil
        taskOrigins[episodeURL] = nil
    }

    func clearTranscriptionState(for episodeURL: URL) async {
        tasks[episodeURL]?.cancel()
        await transcriptionQueue.cancel(episodeURL)
        tasks[episodeURL] = nil
        taskOrigins[episodeURL] = nil
        items[episodeURL] = nil
        episodeSnapshots[episodeURL] = nil
    }

    func queueEntries() async -> [TranscriptionQueueEntry] {
        let snapshot = await transcriptionQueue.snapshot()
        var entries: [TranscriptionQueueEntry] = []

        if let active = snapshot.active,
           let episode = episodeSnapshots[active],
           tasks[active] != nil {
            entries.append(
                TranscriptionQueueEntry(
                    episodeURL: active,
                    episodeTitle: episode.episodeTitle,
                    podcastTitle: episode.podcastTitle,
                    state: .active
                )
            )
        }

        for (index, episodeURL) in snapshot.queued.enumerated() {
            guard let episode = episodeSnapshots[episodeURL], tasks[episodeURL] != nil else { continue }
            entries.append(
                TranscriptionQueueEntry(
                    episodeURL: episodeURL,
                    episodeTitle: episode.episodeTitle,
                    podcastTitle: episode.podcastTitle,
                    state: .queued(position: index + 1)
                )
            )
        }
        return entries
    }

    func moveToFrontOfQueue(episodeURL: URL) async {
        await transcriptionQueue.promote(episodeURL)
    }

    func cancelAutomaticTranscriptionsForBackground() async {
        let automaticEpisodeURLs = taskOrigins.compactMap { (episodeURL, origin) in
            origin == .automatic ? episodeURL : nil
        }

        guard automaticEpisodeURLs.isEmpty == false else { return }

        for episodeURL in automaticEpisodeURLs {
            tasks[episodeURL]?.cancel()
            await transcriptionQueue.cancel(episodeURL)
            if let item = items[episodeURL] {
                await MainActor.run {
                    item.setState(.cancelled, status: "Deferred until app is active")
                }
            }
            tasks[episodeURL] = nil
            taskOrigins[episodeURL] = nil
        }
    }

    /// Starts the next automatic transcription picked from the user's playlists.
    ///
    /// - Parameters:
    ///   - allowOnDeviceFallback: When `false`, only feed-provided transcripts
    ///     are imported and the analyzer is never started.
    ///   - respectSweepCooldown: Foreground sweeps fire on app activation and on
    ///     every power-state change, so they throttle each other. A background
    ///     pass is a rare, deliberate opportunity and passes `false`.
    ///   - deadline: Stops the search for a startable episode. Skipping a
    ///     candidate can mean a failed transcript download, so a long candidate
    ///     list must not be allowed to outlive the caller's window.
    /// - Returns: The episode that was handled, or `nil` when nothing was left
    ///   to do.
    func processNextAutomaticTranscriptionFromPlaylists(
        allowOnDeviceFallback: Bool = true,
        respectSweepCooldown: Bool = true,
        deadline: Date? = nil
    ) async -> URL? {
        guard tasks.isEmpty else { return nil }
        let now = Date()
        if respectSweepCooldown,
           let lastAutomaticSweepAt,
           now.timeIntervalSince(lastAutomaticSweepAt) < automaticSweepCooldown {
            return nil
        }
        lastAutomaticSweepAt = now

        let settingsActor = PodcastSettingsModelActor(modelContainer: container)
        guard await settingsActor.getTranscriptionsEnabled() else {
            return nil
        }

        // Importing a published transcript is a small download and stays allowed
        // even when the user switched the on-device analyzer off or is off power.
        var allowsAnalyzer = allowOnDeviceFallback
        if allowsAnalyzer {
            allowsAnalyzer = await settingsActor.getAutomaticOnDeviceTranscriptionsEnabled()
        }
        if allowsAnalyzer, await settingsActor.getAutomaticOnDeviceTranscriptionsRequiresCharging() {
            allowsAnalyzer = await isDeviceConnectedToPower()
        }

        automaticRetryBlockedUntil = automaticRetryBlockedUntil.filter { $0.value > now }

        let provider = AutomaticTranscriptionCandidateProvider(modelContainer: container)
        let candidates = await provider.candidates(
            limit: automaticScanLimit,
            allowOnDeviceFallback: allowsAnalyzer,
            excluding: Set(items.keys).union(automaticRetryBlockedUntil.keys)
        )
        guard candidates.isEmpty == false else { return nil }

        let episodeActor = EpisodeActor(modelContainer: container)

        for candidate in candidates {
            if Task.isCancelled { return nil }
            if let deadline, Date() >= deadline { return nil }
            let episodeURL = candidate.episodeURL

            try? await episodeActor.transcribe(
                episodeURL,
                allowOnDeviceFallback: candidate.source == .onDevice,
                origin: .automatic
            )

            if tasks[episodeURL] != nil {
                return episodeURL
            }

            // No analyzer job means the episode either got its transcript from
            // the feed just now, or the attempt produced nothing. Re-read it in a
            // fresh context: a stale one would still report the pre-import state.
            let verifier = AutomaticTranscriptionCandidateProvider(modelContainer: container)
            let remainingSource = await verifier.transcriptionSource(
                for: episodeURL,
                allowOnDeviceFallback: allowsAnalyzer
            )
            if remainingSource == nil {
                return episodeURL
            }

            // Still waiting. Park it so the next sweep spends its window on the
            // following episode instead of retrying this one immediately.
            automaticRetryBlockedUntil[episodeURL] = now.addingTimeInterval(automaticRetryCooldown)
        }

        return nil
    }

    /// Works through the playlists until the budget is spent, the episode limit
    /// is reached, or nothing is left to transcribe.
    ///
    /// The budget is only checked before starting another episode: a running
    /// analyzer is left alone so its transcript still gets written, and the
    /// background task's expiration handler cancels it if iOS reclaims the time.
    ///
    /// - Returns: How many episodes were handled.
    @discardableResult
    func runAutomaticTranscriptionsFromPlaylists(
        allowOnDeviceFallback: Bool = true,
        episodeLimit: Int = 1,
        budget: TimeInterval? = nil
    ) async -> Int {
        guard episodeLimit > 0 else { return 0 }
        let deadline = budget.map { Date(timeIntervalSinceNow: $0) }
        var processedCount = 0

        while processedCount < episodeLimit {
            if Task.isCancelled { break }
            if let deadline, Date() >= deadline { break }
            // Back-to-back analyzer runs heat the device up. Stop handing out
            // more work once the system says it is under pressure; the next
            // background pass picks up where this one stopped.
            if processedCount > 0, SystemPressureGate.shared.isUnderPressure { break }

            guard let episodeURL = await processNextAutomaticTranscriptionFromPlaylists(
                allowOnDeviceFallback: allowOnDeviceFallback,
                respectSweepCooldown: false,
                deadline: deadline
            ) else { break }

            processedCount += 1

            // Wait for the analyzer to finish before picking the next episode:
            // two of them at once double e-core pressure and memory.
            if let runningTask = tasks[episodeURL] {
                await runningTask.value
            }
        }

        return processedCount
    }

    private func finish(episodeURL: URL, error: String) async {
        if let item = items[episodeURL] {
            await MainActor.run {
                item.setState(.failed(error: error), status: "Failed: \(error)")
            }
        }
        await cleanUp(episodeURL: episodeURL)
    }

    private func cleanUp(episodeURL: URL) async {
        tasks[episodeURL]?.cancel()
        tasks[episodeURL] = nil
        taskOrigins[episodeURL] = nil
        // keep item around for UI to show finished/failed state
    }

    // MARK: - Actor-isolated helpers

    private func store(item: TranscriptionItem, for episodeURL: URL) {
        items[episodeURL] = item
    }

    private func isDeviceConnectedToPower() async -> Bool {
#if canImport(UIKit)
        await MainActor.run {
            let device = UIDevice.current
            let wasBatteryMonitoringEnabled = device.isBatteryMonitoringEnabled
            if wasBatteryMonitoringEnabled == false {
                device.isBatteryMonitoringEnabled = true
            }

            let isConnectedToPower: Bool
            switch device.batteryState {
            case .charging, .full:
                isConnectedToPower = true
            case .unknown, .unplugged:
                isConnectedToPower = false
            @unknown default:
                isConnectedToPower = false
            }

            if wasBatteryMonitoringEnabled == false {
                device.isBatteryMonitoringEnabled = false
            }

            return isConnectedToPower
        }
#else
        true
#endif
    }
}
