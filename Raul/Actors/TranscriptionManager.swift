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

    // Track jobs by episodeID
    private var items: [UUID: TranscriptionItem] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    // Dependency
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func item(for episodeID: UUID) -> TranscriptionItem? {
        items[episodeID]
    }

    func enqueueTranscription(episodeID: UUID) {
        print("enqueueTranscription")
        // Guard once per episode
        if tasks[episodeID] != nil { return }

        let episodeActor = EpisodeActor(modelContainer: container)

        // Kick off orchestration in a Task, but never carry @Model instances out of EpisodeActor.
        let job = Task(priority: .background) { [weak self] in
            guard let self else { return }

            // Snapshot only value types we need
            guard let (localFile, language) = await episodeActor.episodeLocalFileAndLanguage(for: episodeID) else {
                await self.finish(episodeID: episodeID, error: "Missing local file.")
                return
            }
            print("episode lang: \(language)")
            // Create UI item on MainActor
            let uiItem = await MainActor.run { TranscriptionItem(episodeID: episodeID, sourceURL: localFile) }

            // Store item in actor state
            await self.store(item: uiItem, for: episodeID)

            // Attach item to the episode via EpisodeActor (do not pass Episode around)
            await episodeActor.attachTranscriptionItem(uiItem, to: episodeID)

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
                    uiItem.setState(.preparingModel, status: "Preparing model…")
                }

                // Build transcriber (pure value types: URL + language string)
                let transcriber = await AITranscripts(url: localFile, language: language)
                

                await MainActor.run {
                    uiItem.setState(.downloadingModel(progress: nil), status: "Ensuring language model…")
                }

                await MainActor.run {
                    uiItem.setState(.analyzing, progress: 0.2, status: "Analyzing audio…")
                }

                // Get VTT text as String? (Sendable)
                let vtt = try await transcriber.transcribeTovTT()

                await MainActor.run {
                    uiItem.setState(.saving, progress: 0.9, status: "Saving transcript…")
                }

                if let vtt {
                    // Decode inside EpisodeActor to produce model instances and save there
                    await episodeActor.decodeAndSetTranscript(for: episodeID, vtt: vtt)
                }

                await MainActor.run {
                    uiItem.setState(.finished, progress: 1.0, status: "Finished")
                }
                await self.cleanUp(episodeID: episodeID)
            } catch is CancellationError {
                await MainActor.run {
                    uiItem.setState(.cancelled, status: "Cancelled")
                }
                await self.cleanUp(episodeID: episodeID)
            } catch {
                await self.finish(episodeID: episodeID, error: error.localizedDescription)
            }
        }

        // Register the task in actor state
        tasks[episodeID] = job
    }

    func cancel(episodeID: UUID) {
        tasks[episodeID]?.cancel()
        tasks[episodeID] = nil
    }

    private func finish(episodeID: UUID, error: String) async {
        if let item = items[episodeID] {
            await MainActor.run {
                item.setState(.failed(error: error), status: "Failed: \(error)")
            }
        }
        await cleanUp(episodeID: episodeID)
    }

    private func cleanUp(episodeID: UUID) async {
        tasks[episodeID]?.cancel()
        tasks[episodeID] = nil
        // keep item around for UI to show finished/failed state
    }

    // MARK: - Actor-isolated helpers

    private func store(item: TranscriptionItem, for episodeID: UUID) {
        items[episodeID] = item
    }
}
