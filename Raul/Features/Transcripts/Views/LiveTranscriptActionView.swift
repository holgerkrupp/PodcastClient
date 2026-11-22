import SwiftUI
import SwiftData

struct LiveTranscriptActionView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable private var live = LiveTranscriptController.shared
    @State private var aiGeneration = EpisodeAIGenerationCoordinator.shared
    @StateObject private var downloadViewModel = DownloadViewModel()
    let episode: Episode

    var body: some View {
        VStack(spacing: 6) {
            if live.pendingSaveEpisodeURL == episode.url {
                Text("Some captions are waiting to be saved. Keep Up Next open and check available storage.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry saving") { live.retryPendingSaves() }
                    .font(.caption)
            }

            if isLocalMediaAvailable {
                EpisodeAIGenerationControl(
                    action: .transcribe,
                    state: episode.url.flatMap { aiGeneration.state(for: $0) },
                    start: { action in
                        guard let episodeURL = episode.url else { return }
                        aiGeneration.start(
                            action: action,
                            episodeURL: episodeURL,
                            modelContainer: modelContext.container
                        )
                    },
                    cancel: {
                        if let episodeURL = episode.url {
                            Task { await aiGeneration.cancel(episodeURL: episodeURL) }
                        }
                    }
                )
                .frame(maxWidth: .infinity)
            } else if isDownloadInProgress {
                Text("Downloading episode…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress = downloadViewModel.item?.progress, progress > 0 {
                    ProgressView(value: progress)
                        .frame(maxWidth: 180)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if episode.source == .sideLoaded {
                Text("The side-loaded file is unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Download episode") {
                    downloadViewModel.startDownload(for: episode)
                }
                .buttonStyle(.bordered)
            }

            if isFullTranscriptionRunning {
                Text("Full transcription is in progress. Live transcription will be available when it finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if live.isActive(for: episode) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Stop live transcription") { live.stop() }
                    .buttonStyle(.bordered)
            } else if isLocalMediaAvailable {
                if live.episodeURL == episode.url,
                   live.phase == .unavailable,
                   let reason = live.unavailableReason {
                    Text(reason.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Transcribe as you listen") {
                    Task {
                        await live.start(episode: episode, container: modelContext.container)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(8)
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
        guard let item = downloadViewModel.item else { return false }
        return item.isDownloading || item.isPaused
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
        case .following: "Transcribing as you listen"
        case .idle, .unavailable: "Transcription unavailable"
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
