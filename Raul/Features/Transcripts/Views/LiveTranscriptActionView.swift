import SwiftUI
import SwiftData

struct LiveTranscriptActionView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable private var live = LiveTranscriptController.shared
    let episode: Episode

    var body: some View {
        VStack(spacing: 6) {
            if live.pendingSaveEpisodeURL == episode.url {
                Text("Some captions are waiting to be saved. Keep Up Next open and check available storage.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry saving") { live.retryPendingSaves() }
                    .font(.caption)
            }
            if live.isActive(for: episode) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Stop live transcription") { live.stop() }
                    .buttonStyle(.bordered)
            } else if episode.localFile != nil {
                if live.episodeURL == episode.url && live.phase == .unavailable {
                    Text("Live transcription is unavailable for this audio or language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Transcribe as you listen") {
                    live.start(episode: episode, container: modelContext.container)
                }
                .buttonStyle(.bordered)
            } else {
                Text("Download this episode to transcribe as you listen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(8)
        .onAppear { live.retryPendingSaves() }
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
