import SwiftUI
import SwiftData

struct TranscriptEmptyStateView: View {
    let episode: Episode

    var body: some View {
        ContentUnavailableView {
            Label("No Transcript", systemImage: "quote.bubble")
        } description: {
            Text("Generate a transcript to read along with this episode.")
        } actions: {
            TranscriptGenerationActionsView(episode: episode)
        }
    }
}

struct TranscriptGenerationActionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable private var live = LiveTranscriptController.shared
    @State private var aiGeneration = EpisodeAIGenerationCoordinator.shared
    @StateObject private var downloadViewModel = DownloadViewModel()
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pendingURL = live.pendingSaveEpisodeURL, pendingURL == episode.url {
                Text("Some captions are waiting to be saved. Keep Up Next open and check available storage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry saving") { live.retryPendingSaves() }
                    .font(.caption)
            }

            if isLocalMediaAvailable {
                fullTranscriptionControl

                Divider()

                liveTranscriptionControl
            } else if isDownloadInProgress {
                Label("Downloading episode…", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
                if let progress = downloadViewModel.item?.progress, progress > 0 {
                    ProgressView(value: progress)
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if episode.source == .sideLoaded {
                Label("The side-loaded file is unavailable.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Download the episode to create a full transcript or transcribe as you listen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    downloadViewModel.startDownload(for: episode)
                } label: {
                    Label("Download episode", systemImage: "arrow.down.circle")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.glass(.clear))
            }
        }
        .onAppear { live.retryPendingSaves() }
        .task(id: episode.url) {
            await downloadViewModel.observeDownload(for: episode)
        }
    }

    private var isLocalMediaAvailable: Bool {
        guard let localFile = episode.localFile else { return false }
        return FileManager.default.fileExists(atPath: localFile.path)
    }

    private var isDownloadInProgress: Bool {
        if downloadViewModel.isStarting { return true }
        guard let item = downloadViewModel.item else { return false }
        return downloadViewModel.isStarting || item.isDownloading || item.isPaused
    }

    private var isFullTranscriptionRunning: Bool {
        guard let episodeURL = episode.url else { return false }
        guard case .running = aiGeneration.state(for: episodeURL) else { return false }
        return aiGeneration.isRunning(for: episodeURL)
    }

    private var status: LocalizedStringKey {
        switch live.phase {
        case .preparing: "Preparing transcription…"
        case .catchingUp: "Transcription is catching up…"
        case .following: "Transcribing…"
        case .idle, .unavailable: "Transcription unavailable"
        }
    }

    private var fullTranscriptionState: EpisodeAIGenerationState? {
        episode.url.flatMap { aiGeneration.state(for: $0) }
    }

    @ViewBuilder
    private var fullTranscriptionControl: some View {
        EpisodeAIGenerationControl(
            action: .transcribe,
            state: fullTranscriptionState,
            start: { _ in startFullTranscription() },
            cancel: cancelFullTranscription
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var liveTranscriptionControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcribe as you listen")
                .font(.subheadline.weight(.semibold))
            Text("Follows the current playback position and saves analyzed portions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isFullTranscriptionRunning {
                Text("Available after full transcription finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if live.isActive(for: episode) {
                HStack(spacing: 8) {
                    Label(status, systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Stop transcription") { live.stopByUser() }
                        .buttonStyle(.glass(.clear))
                }
            } else {
                if live.phase == .preparing, live.episodeURL == episode.url {
                    Label("Preparing local playback…", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if live.episodeURL == episode.url,
                          live.phase == .unavailable,
                          let reason = live.unavailableReason {
                    Text(reason.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    startLiveTranscription()
                } label: {
                    Label("Transcribe as you listen", systemImage: "waveform")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.glass(.clear))
                .disabled(isStartingLive)
            }
        }
    }

    private var isStartingLive: Bool {
        live.phase == .preparing || live.phase == .catchingUp
    }

    private func startFullTranscription() {
        guard let episodeURL = episode.url, isLocalMediaAvailable else { return }
        aiGeneration.start(
            action: .transcribe,
            episodeURL: episodeURL,
            modelContainer: modelContext.container
        )
    }

    private func cancelFullTranscription() {
        guard let episodeURL = episode.url else { return }
        Task { await aiGeneration.cancel(episodeURL: episodeURL) }
    }

    private func startLiveTranscription() {
        Task {
            await live.start(episode: episode, container: modelContext.container)
        }
    }
}

struct LiveTranscriptCoverageView: View {
    @Bindable private var live = LiveTranscriptController.shared
    let episode: Episode

    private var ranges: [LiveTranscriptState.Coverage] {
        if live.isActive(for: episode) { return live.coverage }
        guard let data = episode.liveTranscriptData,
              let state = try? JSONDecoder().decode(LiveTranscriptState.self, from: data) else { return [] }
        return state.coverage
    }

    var body: some View {
        let visible = ranges.prefix(3).map { "\(format($0.start))–\(format($0.end))" }.joined(separator: ", ")
        VStack(spacing: 2) {
            Text("Partial transcript: only analyzed portions are available.")
            if !visible.isEmpty {
                if ranges.count > 3 { Text("Analyzed: \(visible), and more") }
                else { Text("Analyzed: \(visible)") }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    private func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0, time < Double(Int.max) else { return "–" }
        let value = Int(time)
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}
