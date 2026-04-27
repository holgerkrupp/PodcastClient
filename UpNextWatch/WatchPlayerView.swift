import SwiftUI

enum WatchPlayerPresentationStyle {
    case page
    case pushed
}

struct WatchPlayerView: View {
    @EnvironmentObject private var store: WatchSyncStore
    @EnvironmentObject private var playback: WatchPlaybackController

    let episodeID: String
    var presentationStyle: WatchPlayerPresentationStyle = .pushed

    private var episode: WatchSyncEpisode? {
        store.episode(withID: episodeID)
            ?? (playback.currentEpisode?.id == episodeID ? playback.currentEpisode : nil)
    }

    private var activePosition: Double {
        guard let episode else { return 0 }
        return playback.isCurrentEpisode(episode) ? playback.playPosition : (episode.playPosition ?? 0)
    }

    private var activeChapter: WatchSyncChapter? {
        guard let episode else { return nil }
        return playback.isCurrentEpisode(episode) ? playback.currentChapter : episode.chapter(at: episode.playPosition)
    }

    var body: some View {
        Group {
            if presentationStyle == .pushed {
                playerBody
                    .navigationTitle("Player")
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                playerBody
            }
        }
        .onDisappear {
            playback.flushProgress()
        }
    }

    private var playerBody: some View {
        ZStack {
            WatchAppBackground()

            if let episode {
                ScrollView {
                    VStack(spacing: 12) {
                        WatchArtworkView(
                            url: playback.artworkURL(for: episode),
                            title: episode.title,
                            icon: playback.isActivelyPlaying(episode) ? "waveform" : "play.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)

                        VStack(spacing: 4) {
                            Text(episode.title)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)

                            if let podcastTitle = episode.podcastTitle, podcastTitle.isEmpty == false {
                                Text(podcastTitle)
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.84))
                                    .multilineTextAlignment(.center)
                            }

                            if let activeChapter {
                                Text(activeChapter.title)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(Color.white.opacity(0.14))
                                    )
                            }
                        }

                        WatchPanel {
                            VStack(spacing: 8) {
                                WatchProgressBar(progress: playback.isCurrentEpisode(episode) ? playback.progress : (episode.playbackProgress ?? 0))

                                HStack {
                                    Text(watchPlaybackTime(activePosition))
                                    Spacer()
                                    Text(watchPlaybackTime(episode.duration ?? 0))
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.84))
                            }
                        }

                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                WatchSmallControlButton(
                                    systemName: "backward.end.fill",
                                    accessibilityLabel: "Previous chapter",
                                    accessibilityHint: "Jumps to the start of the previous chapter"
                                ) {
                                    if playback.isCurrentEpisode(episode) {
                                        playback.skipToChapterStart()
                                    } else {
                                        playback.play(episode, startingAt: max(activePosition - 3, 0))
                                    }
                                }

                                WatchPrimaryControlButton(
                                    systemName: playback.isActivelyPlaying(episode) ? "pause.fill" : "play.fill",
                                    accessibilityLabel: playback.isActivelyPlaying(episode) ? "Pause playback" : "Start playback",
                                    accessibilityHint: playback.isActivelyPlaying(episode) ? "Pauses the current episode" : "Starts the current episode"
                                ) {
                                    playback.togglePlayback(for: episode)
                                }

                                WatchSmallControlButton(
                                    systemName: "forward.end.fill",
                                    accessibilityLabel: "Next chapter",
                                    accessibilityHint: "Skips to the next chapter"
                                ) {
                                    if playback.isCurrentEpisode(episode) {
                                        playback.skipToNextChapter()
                                    } else if let nextChapter = episode.chapters.first(where: { $0.start > activePosition }) {
                                        playback.play(episode, startingAt: nextChapter.start)
                                    }
                                }
                            }

                            HStack(spacing: 8) {
                                WatchSmallControlButton(
                                    systemName: playback.skipBackSystemName,
                                    accessibilityLabel: "Skip back \(playback.skipBackSeconds) seconds",
                                    accessibilityHint: "Moves playback backward by \(playback.skipBackSeconds) seconds"
                                ) {
                                    if playback.isCurrentEpisode(episode) {
                                        playback.skipBackward()
                                    } else {
                                        playback.play(episode, startingAt: max(activePosition - Double(playback.skipBackSeconds), 0))
                                    }
                                }

                                WatchSmallControlButton(
                                    systemName: playback.skipForwardSystemName,
                                    accessibilityLabel: "Skip forward \(playback.skipForwardSeconds) seconds",
                                    accessibilityHint: "Moves playback forward by \(playback.skipForwardSeconds) seconds"
                                ) {
                                    if playback.isCurrentEpisode(episode) {
                                        playback.skipForward()
                                    } else {
                                        playback.play(episode, startingAt: activePosition + Double(playback.skipForwardSeconds))
                                    }
                                }

                                Button(playback.formattedPlaybackRate) {
                                    playback.cyclePlaybackRate()
                                }
                                .buttonStyle(WatchCapsuleButtonStyle(accent: .teal))
                                .accessibilityLabel("Playback speed")
                                .accessibilityValue(playback.formattedPlaybackRate)
                                .accessibilityHint("Double tap to cycle playback speed")
                            }
                        }

                        if episode.chapters.isEmpty == false {
                            WatchPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Chapters")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.84))

                                    ForEach(episode.chapters) { chapter in
                                        Button {
                                            playback.play(episode, startingAt: chapter.start)
                                        } label: {
                                            HStack(spacing: 8) {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(chapter.title)
                                                        .font(.caption)
                                                        .multilineTextAlignment(.leading)
                                                        .foregroundStyle(.white)
                                                        .frame(maxWidth: .infinity, alignment: .leading)

                                                    Text(watchPlaybackTime(chapter.start))
                                                        .font(.caption2.monospacedDigit())
                                                        .foregroundStyle(.white.opacity(0.78))
                                                }

                                                if activeChapter?.id == chapter.id {
                                                    Image(systemName: "dot.radiowaves.left.and.right")
                                                        .font(.caption2)
                                                        .foregroundStyle(.teal)
                                                        .accessibilityHidden(true)
                                                }
                                            }
                                            .padding(.vertical, 2)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Play chapter \(chapter.title)")
                                        .accessibilityHint("Starts playback at \(watchPlaybackTime(chapter.start))")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.slash")
                        .font(.title3)
                        .accessibilityHidden(true)
                    Text("Episode is no longer available here.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.82))
                .padding()
            }
        }
    }
}

struct WatchAppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.11, blue: 0.17),
                    Color(red: 0.05, green: 0.19, blue: 0.22),
                    Color(red: 0.02, green: 0.04, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(red: 0.92, green: 0.53, blue: 0.21).opacity(0.22))
                .frame(width: 96, height: 96)
                .blur(radius: 16)
                .offset(x: 38, y: -58)

            Circle()
                .fill(Color.teal.opacity(0.18))
                .frame(width: 112, height: 112)
                .blur(radius: 20)
                .offset(x: -44, y: 72)
        }
        .ignoresSafeArea()
    }
}

struct WatchPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

struct WatchArtworkView: View {
    let url: URL?
    let title: String
    var icon: String = "music.note"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.56, blue: 0.23),
                            Color(red: 0.09, green: 0.53, blue: 0.57)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                    switch phase {
                    case .empty:
                        WatchArtworkPlaceholder(title: title, icon: icon)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        WatchArtworkPlaceholder(title: title, icon: icon)
                    @unknown default:
                        WatchArtworkPlaceholder(title: title, icon: icon)
                    }
                }
            } else {
                WatchArtworkPlaceholder(title: title, icon: icon)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }
}

private struct WatchArtworkPlaceholder: View {
    let title: String
    let icon: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack {
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.56)],
                startPoint: .center,
                endPoint: .bottom
            )

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .padding(10)
        }
    }
}

struct WatchProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.orange, .teal],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 8)
    }
}

private struct WatchPrimaryControlButton: View {
    let systemName: String
    let accessibilityLabelText: String
    let accessibilityHintText: String?
    let action: () -> Void

    init(
        systemName: String,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.accessibilityLabelText = accessibilityLabel
        self.accessibilityHintText = accessibilityHint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline.weight(.bold))
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.orange, .teal],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(accessibilityHintText ?? "")
    }
}

private struct WatchSmallControlButton: View {
    let systemName: String
    let accessibilityLabelText: String
    let accessibilityHintText: String?
    let action: () -> Void

    init(
        systemName: String,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.accessibilityLabelText = accessibilityLabel
        self.accessibilityHintText = accessibilityHint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(accessibilityHintText ?? "")
    }
}

struct WatchCapsuleButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                Capsule()
                    .fill(accent.opacity(configuration.isPressed ? 0.4 : 0.28))
            )
    }
}

func watchPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }

    let totalSeconds = Int(max(seconds, 0))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let remainingSeconds = totalSeconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    return String(format: "%d:%02d", minutes, remainingSeconds)
}
