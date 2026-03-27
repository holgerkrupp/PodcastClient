import Foundation
import SwiftData
import UIKit

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

    // Dependency
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func item(for episodeURL: URL) -> TranscriptionItem? {
        items[episodeURL]
    }

    func enqueueTranscription(episodeURL: URL) async -> TranscriptionItem? {
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
                var taskID: UIBackgroundTaskIdentifier = .invalid
                taskID = UIApplication.shared.beginBackgroundTask(withName: "Transcription") {
                    UIApplication.shared.endBackgroundTask(taskID)
                }
                return taskID
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

                // Build transcriber (pure value types: URL + language string)
                let transcriber = await AITranscripts(
                    url: snapshot.localFile,
                    language: snapshot.language,
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
        return uiItem
    }

    func cancel(episodeURL: URL) {
        tasks[episodeURL]?.cancel()
        tasks[episodeURL] = nil
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
        // keep item around for UI to show finished/failed state
    }

    // MARK: - Actor-isolated helpers

    private func store(item: TranscriptionItem, for episodeURL: URL) {
        items[episodeURL] = item
    }
}
