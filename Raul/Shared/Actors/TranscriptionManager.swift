import Foundation
import SwiftData
import UIKit

enum TranscriptionStartOrigin: Sendable {
    case manual
    case automatic
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
    private var automaticScanCursor = 0
    private var lastAutomaticSweepAt: Date?
    private let automaticScanLimit = 12
    private let automaticSweepCooldown: TimeInterval = 30

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

        // Kick off orchestration in a Task, but never carry @Model instances out of EpisodeActor.
        let job = Task(priority: .background) { [weak self] in
            guard let self else { return }

            let startedAt = Date()
            print("episode lang: \(snapshot.language ?? "nil")")

            // Background task is MainActor-only; keep its lifetime there
            let bgTaskID: UIBackgroundTaskIdentifier = await MainActor.run { () -> UIBackgroundTaskIdentifier in
                guard origin == .manual else { return .invalid }
                return UIApplication.shared.beginBackgroundTask(
                    withName: "Transcription",
                    expirationHandler: nil
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

            do {
                await MainActor.run {
                    uiItem.setState(.preparingModel, progress: 0.02, status: "Preparing model…")
                }

                let settingsActor = PodcastSettingsModelActor(modelContainer: container)
                let maxSnippetDurationSeconds = await settingsActor.getTranscriptionMaxSnippetDurationSeconds()

                // Build transcriber (pure value types: URL + language string)
                let transcriber = await AITranscripts(
                    url: snapshot.localFile,
                    language: snapshot.language,
                    maxSnippetDurationSeconds: maxSnippetDurationSeconds,
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

                // Decode inside EpisodeActor to produce model instances and save there
                await episodeActor.decodeAndSetTranscript(for: episodeURL, vtt: vtt)
                let finishedAt = Date()
                await episodeActor.saveTranscriptionRecord(
                    for: snapshot,
                    localeIdentifier: transcriber.language.identifier(.bcp47),
                    startedAt: startedAt,
                    finishedAt: finishedAt
                )

                await MainActor.run {
                    uiItem.setState(.finished, progress: 1.0, status: "Finished")
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

    func cancel(episodeURL: URL) {
        tasks[episodeURL]?.cancel()
        tasks[episodeURL] = nil
        taskOrigins[episodeURL] = nil
    }

    func cancelAutomaticTranscriptionsForBackground() async {
        let automaticEpisodeURLs = taskOrigins.compactMap { (episodeURL, origin) in
            origin == .automatic ? episodeURL : nil
        }

        guard automaticEpisodeURLs.isEmpty == false else { return }

        for episodeURL in automaticEpisodeURLs {
            tasks[episodeURL]?.cancel()
            if let item = items[episodeURL] {
                await MainActor.run {
                    item.setState(.cancelled, status: "Deferred until app is active")
                }
            }
            tasks[episodeURL] = nil
            taskOrigins[episodeURL] = nil
        }
    }

    func processNextAutomaticTranscriptionFromUpNext(
        allowOnDeviceFallback: Bool = true
    ) async -> URL? {
        guard tasks.isEmpty else { return nil }
        let now = Date()
        if let lastAutomaticSweepAt,
           now.timeIntervalSince(lastAutomaticSweepAt) < automaticSweepCooldown {
            return nil
        }
        lastAutomaticSweepAt = now

        let settingsActor = PodcastSettingsModelActor(modelContainer: container)
        guard await settingsActor.getAutomaticOnDeviceTranscriptionsEnabled() else {
            return nil
        }

        let requiresCharging = await settingsActor.getAutomaticOnDeviceTranscriptionsRequiresCharging()
        let isConnectedToPower = requiresCharging ? await isDeviceConnectedToPower() : true
        if isConnectedToPower == false {
            return nil
        }

        let playlistActor: PlaylistModelActor
        do {
            playlistActor = try PlaylistModelActor(modelContainer: container)
        } catch {
            return nil
        }

        let upNextEpisodeURLs: [URL]
        do {
            upNextEpisodeURLs = try await playlistActor.orderedEpisodeURLs()
        } catch {
            return nil
        }
        guard upNextEpisodeURLs.isEmpty == false else { return nil }

        let episodeActor = EpisodeActor(modelContainer: container)
        let scanCount = min(automaticScanLimit, upNextEpisodeURLs.count)

        for offset in 0..<scanCount {
            let index = (automaticScanCursor + offset) % upNextEpisodeURLs.count
            let episodeURL = upNextEpisodeURLs[index]
            guard items[episodeURL] == nil else { continue }
            let wasReady = await episodeActor.isReadyForAutomaticTranscription(episodeURL: episodeURL)
            guard wasReady else { continue }

            try? await episodeActor.transcribe(
                episodeURL,
                allowOnDeviceFallback: allowOnDeviceFallback,
                origin: .automatic
            )

            automaticScanCursor = (index + 1) % upNextEpisodeURLs.count

            if tasks[episodeURL] != nil {
                return episodeURL
            }

            // If the episode stopped being "ready" after transcribe(), we likely imported
            // a feed-provided transcript without spawning an on-device task.
            let isStillReady = await episodeActor.isReadyForAutomaticTranscription(episodeURL: episodeURL)
            if isStillReady == false {
                return episodeURL
            }
        }

        automaticScanCursor = (automaticScanCursor + scanCount) % upNextEpisodeURLs.count
        return nil
    }

    func runAutomaticTranscriptionsFromUpNextUntilIdle(
        allowOnDeviceFallback: Bool = true
    ) async -> Bool {
        guard let startedEpisodeURL = await processNextAutomaticTranscriptionFromUpNext(
            allowOnDeviceFallback: allowOnDeviceFallback
        ) else {
            return false
        }

        // Process at most one automatic job per invocation to keep background CPU bounded.
        if let runningTask = tasks[startedEpisodeURL] {
            await runningTask.value
        }

        return true
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
    }
}
