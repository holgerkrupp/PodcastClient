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

    func enqueueTranscription(episodeID: UUID) async -> TranscriptionItem? {
        print("enqueueTranscription")
        if let existingItem = items[episodeID] {
            return existingItem
        }

        let episodeActor = EpisodeActor(modelContainer: container)
        guard let snapshot = await episodeActor.transcriptionSnapshot(for: episodeID) else {
            await finish(episodeID: episodeID, error: "Missing local file.")
            return nil
        }

        let uiItem = await MainActor.run { () -> TranscriptionItem in
            let item = TranscriptionItem(episodeID: episodeID, sourceURL: snapshot.localFile)
            item.setState(.queued, progress: 0.0, status: "Queued")
            return item
        }

        store(item: uiItem, for: episodeID)
        await episodeActor.attachTranscriptionItem(uiItem, to: episodeID)

        if tasks[episodeID] != nil {
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
                await episodeActor.decodeAndSetTranscript(for: episodeID, vtt: vtt)
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
        return uiItem
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
