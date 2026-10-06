import Foundation
import Observation
import SwiftData
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

enum EpisodeAIGenerationAction: String, Equatable, Sendable {
    case transcribe
    case generateChapters
    case transcribeAndGenerateChapters

    var title: LocalizedStringResource {
        switch self {
        case .transcribe: "Transcribe"
        case .generateChapters: "Generate chapters"
        case .transcribeAndGenerateChapters: "Transcribe & generate chapters"
        }
    }
}

enum EpisodeAIGenerationState: Equatable, Sendable {
    case unavailable
    case idle(EpisodeAIGenerationAction)
    case running(status: String, progress: Double?)
    case finished
    case failed(String)
}

enum EpisodeAIGenerationPolicy {
    static func action(
        isAvailable: Bool,
        hasTranscript: Bool,
        hasUsableChapters: Bool
    ) -> EpisodeAIGenerationAction? {
        guard isAvailable else { return nil }
        return switch (hasTranscript, hasUsableChapters) {
        case (false, false): .transcribeAndGenerateChapters
        case (false, true): .transcribe
        case (true, false): .generateChapters
        case (true, true): nil
        }
    }
}

enum AppleIntelligenceAvailability {
    static var isAvailable: Bool {
#if canImport(FoundationModels)
        SystemLanguageModel.default.isAvailable
#else
        false
#endif
    }
}

@MainActor
@Observable
final class EpisodeAIGenerationCoordinator {
    static let shared = EpisodeAIGenerationCoordinator()

    private(set) var jobs: [URL: EpisodeAIGenerationState] = [:]
    @ObservationIgnored private var tasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var transcriptionItems: [URL: TranscriptionItem] = [:]
    @ObservationIgnored private var cleanupTasks: [URL: Task<Void, Never>] = [:]

    private init() {}

    func state(for url: URL) -> EpisodeAIGenerationState? {
        jobs[url]
    }

    func start(
        action: EpisodeAIGenerationAction,
        episodeURL: URL,
        modelContainer: ModelContainer
    ) {
        guard tasks[episodeURL] == nil else { return }
        cleanupTasks.removeValue(forKey: episodeURL)?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(action: action, episodeURL: episodeURL, modelContainer: modelContainer)
        }
        tasks[episodeURL] = task
    }

    func cancel(episodeURL: URL) async {
        let task = tasks[episodeURL]
        task?.cancel()
        await TranscriptionManager.shared.cancel(episodeURL: episodeURL)
        await task?.value
        jobs[episodeURL] = nil
        tasks[episodeURL] = nil
        transcriptionItems[episodeURL] = nil
    }

    private func run(
        action: EpisodeAIGenerationAction,
        episodeURL: URL,
        modelContainer: ModelContainer
    ) async {
        let actor = EpisodeActor(modelContainer: modelContainer)
        do {
            if action != .generateChapters {
                jobs[episodeURL] = .running(status: String(localized: "Preparing transcript…"), progress: nil)
                try await actor.transcribe(episodeURL, origin: .manual)
                guard Task.isCancelled == false else { throw CancellationError() }
                guard let item = await TranscriptionManager.shared.item(for: episodeURL) else {
                    // A publisher transcript may have been imported synchronously.
                    if action == .transcribe {
                        jobs[episodeURL] = .finished
                        tasks[episodeURL] = nil
                        scheduleCleanup(for: episodeURL)
                        return
                    }
                    guard await actor.hasTranscript(for: episodeURL) else {
                        throw EpisodeAIGenerationError.transcriptUnavailable
                    }
                    try await generateChapters(actor: actor, episodeURL: episodeURL)
                    return
                }
                transcriptionItems[episodeURL] = item
                while item.isTranscribing {
                    try Task.checkCancellation()
                    jobs[episodeURL] = .running(
                        status: transcriptionStatus(for: item),
                        progress: transcriptionProgress(for: item)
                    )
                    try await Task.sleep(for: .milliseconds(300))
                }
                switch item.state {
                case .finished: break
                case .cancelled: throw CancellationError()
                case .failed(let message): throw EpisodeAIGenerationError.transcriptionFailed(message)
                default:
                    guard await actor.hasTranscript(for: episodeURL) else { throw EpisodeAIGenerationError.transcriptUnavailable }
                }
                guard Task.isCancelled == false else { throw CancellationError() }
                if action == .transcribe {
                    jobs[episodeURL] = .finished
                    tasks[episodeURL] = nil
                    scheduleCleanup(for: episodeURL)
                    return
                }
            }
            try await generateChapters(actor: actor, episodeURL: episodeURL)
        } catch is CancellationError {
            jobs[episodeURL] = nil
        } catch {
            jobs[episodeURL] = .failed(error.localizedDescription)
        }
        tasks[episodeURL] = nil
        transcriptionItems[episodeURL] = nil
        if jobs[episodeURL] != nil { scheduleCleanup(for: episodeURL) }
    }

    private func generateChapters(actor: EpisodeActor, episodeURL: URL) async throws {
        try Task.checkCancellation()
        jobs[episodeURL] = .running(status: String(localized: "Generating chapters…"), progress: nil)
        let generated = await actor.generateChaptersOnDemand(for: episodeURL) { [weak self] status in
            Task { @MainActor in
                guard let self, self.tasks[episodeURL]?.isCancelled == false else { return }
                self.jobs[episodeURL] = .running(status: status, progress: nil)
            }
        }
        try Task.checkCancellation()
        guard generated else { throw EpisodeAIGenerationError.chaptersUnavailable }
        jobs[episodeURL] = .finished
    }

    private func transcriptionStatus(for item: TranscriptionItem) -> String {
        switch item.state {
        case .queued: String(localized: "Queued for transcription")
        case .preparingModel: String(localized: "Preparing transcript…")
        case .downloadingModel: String(localized: "Preparing speech model…")
        case .analyzing: String(localized: "Transcribing…")
        case .saving: String(localized: "Saving transcript…")
        case .finished: String(localized: "Transcript ready")
        case .failed(let message): message
        case .cancelled: String(localized: "Generation cancelled")
        case .idle: String(localized: "Preparing transcript…")
        }
    }

    private func transcriptionProgress(for item: TranscriptionItem) -> Double? {
        switch item.state {
        case .downloadingModel(let progress): progress
        case .analyzing, .saving: item.progress
        case .queued, .preparingModel, .finished, .failed, .cancelled, .idle: nil
        }
    }

    private func scheduleCleanup(for episodeURL: URL) {
        cleanupTasks.removeValue(forKey: episodeURL)?.cancel()
        guard let terminalState = jobs[episodeURL] else { return }
        cleanupTasks[episodeURL] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard Task.isCancelled == false,
                  let self,
                  self.jobs[episodeURL] == terminalState,
                  self.tasks[episodeURL] == nil else { return }
            self.jobs[episodeURL] = nil
            self.cleanupTasks[episodeURL] = nil
        }
    }
}

struct EpisodeAIGenerationControl: View {
    let action: EpisodeAIGenerationAction?
    let state: EpisodeAIGenerationState?
    let start: (EpisodeAIGenerationAction) -> Void
    let cancel: () -> Void

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var body: some View {
        if isRunning, case let .running(status, progress) = state {
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 28)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(status).font(.caption).lineLimit(2).minimumScaleFactor(0.8)
                    .accessibilityLabel(status)
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel generation")
                .accessibilityHint("Stops transcript and chapter generation")
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .contain)
        } else if case let .failed(message) = state, let action {
            HStack(spacing: 8) {
                Text(message).font(.caption).lineLimit(2)
                Button { start(action) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(action.title)
            }
        } else if let action {
            Button { start(action) } label: {
                Label(action.title, systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.glass(.clear))
            .accessibilityHint("Uses Apple Intelligence on this device")
        }
    }
}

private enum EpisodeAIGenerationError: LocalizedError {
    case transcriptUnavailable
    case chaptersUnavailable
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .transcriptUnavailable: String(localized: "The transcript could not be created. Download the episode and try again.")
        case .chaptersUnavailable: String(localized: "No chapters could be generated from this transcript.")
        case .transcriptionFailed(let message): message
        }
    }
}
