import SwiftUI
import UIKit
import AVFoundation
import WatchKit

extension Color {
    static let upNextAccent = Color("AccentColor")
}

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
        return playback.isCurrentEpisode(episode) ? playback.displayedPlayPosition : (episode.playPosition ?? 0)
    }

    private var activeChapter: WatchSyncChapter? {
        guard let episode else { return nil }
        return playback.isCurrentEpisode(episode) ? playback.currentChapter : episode.chapter(at: episode.playPosition)
    }

    private var remotePlaybackUnavailable: Bool {
        store.isRemoteControlEnabled && !playback.remotePlaybackAvailable
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
                        HStack {
                            Spacer()
                            Button {
                                playback.presentAudioOutputGuidance()
                            } label: {
                                Image(systemName: "airplayaudio")
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .accessibilityLabel("Audio Output")
                            .accessibilityValue(playback.audioOutputName)
                            .accessibilityHint("Choose an audio destination from the system controls")
                            .disabled(remotePlaybackUnavailable)
                        }

                        WatchArtworkView(
                            url: playback.artworkURL(for: episode),
                            title: episode.title
                        )
                        .frame(width: 112, height: 112)
                        .frame(maxWidth: .infinity, alignment: .center)

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
                        if remotePlaybackUnavailable {
                            Label(
                                "iPhone playback is unavailable or out of date.",
                                systemImage: "iphone.slash"
                            )
                            .font(.caption2)
                            .foregroundStyle(.orange)
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
                        
                            VStack(spacing: 8) {
                                Spacer()
                                WatchProgressBar(progress: playback.isCurrentEpisode(episode) ? playback.progress : (episode.playbackProgress ?? 0))

                                HStack {
                                    Text(watchPlaybackTime(activePosition))
                                    Spacer()
                                    Text(watchPlaybackTime(episode.duration ?? 0))
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.84))
                            }
                        

                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                WatchSmallControlButton(
                                    systemName: skipBackSystemName(for: episode),
                                    accessibilityLabel: skipBackLabel(for: episode),
                                    accessibilityHint: skipBackHint(for: episode)
                                ) {
                                    if playback.isCurrentEpisode(episode) {
                                        playback.skipBackward()
                                    } else {
                                        playback.play(episode, startingAt: skipBackPosition(for: episode))
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
                                    systemName: skipForwardSystemName(for: episode),
                                    accessibilityLabel: skipForwardLabel(for: episode),
                                    accessibilityHint: skipForwardHint(for: episode)
                                ) {
                                    if playback.isCurrentEpisode(episode) {
                                        playback.skipForward()
                                    } else {
                                        playback.play(episode, startingAt: skipForwardPosition(for: episode))
                                    }
                                }
                            }

                            HStack(spacing: 8) {
                                Button(playback.formattedPlaybackRate(for: episode)) {
                                    playback.cyclePlaybackRate(for: episode)
                                }
                                .buttonStyle(WatchCapsuleButtonStyle(accent: .upNextAccent))
                                .accessibilityLabel("Playback speed")
                                .accessibilityValue(playback.formattedPlaybackRate(for: episode))
                                .accessibilityHint("Double tap to cycle playback speed")

                                WatchPlayerVolumeRow(
                                    canAdjustVolume: canAdjustVolume(for: episode),
                                    unavailableMessage: "Volume is available while the selected audio source is connected and playing.",
                                    origin: store.isRemoteControlEnabled ? .companion : .local
                                )
                            }
                            .disabled(remotePlaybackUnavailable)
                        }

                        if episode.chapters.isEmpty == false {
                            WatchPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Chapters")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.84))

                                    ForEach(episode.chapters) { chapter in
                                        VStack(alignment: .leading, spacing: 6) {
                                            Button {
                                                if playback.isCurrentEpisode(episode) {
                                                    playback.playChapter(chapter)
                                                } else {
                                                    playback.play(episode, startingAt: chapter.start)
                                                }
                                            } label: {
                                                HStack(spacing: 8) {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(chapter.title)
                                                            .font(.caption)
                                                            .multilineTextAlignment(.leading)
                                                            .foregroundStyle(activeChapter?.id == chapter.id ? .white : .white.opacity(0.54))
                                                            .frame(maxWidth: .infinity, alignment: .leading)

                                                        Text(watchPlaybackTime(chapter.start))
                                                            .font(.caption2.monospacedDigit())
                                                            .foregroundStyle(.white.opacity(activeChapter?.id == chapter.id ? 0.78 : 0.48))
                                                    }

                                                    
                                                    Toggle("Play chapter", isOn: Binding(
                                                        get: { chapter.shouldPlay == true },
                                                        set: { newValue in
                                                            store.setChapterShouldPlay(newValue, chapterID: chapter.id, episodeID: episode.episodeURL)
                                                        }
                                                    ))
                                                    .toggleStyle(SkipChapter())
                                                    .font(.caption2)
                                                    .labelsHidden()
                                                    
                                                    /*
                                                    if activeChapter?.id == chapter.id {
                                                        Image(systemName: "dot.radiowaves.left.and.right")
                                                            .font(.caption2)
                                                            .foregroundStyle(.teal)
                                                            .accessibilityHidden(true)
                                                    }
                                                     */
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
                            .disabled(remotePlaybackUnavailable)
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

    private func canAdjustVolume(for episode: WatchSyncEpisode) -> Bool {
        guard playback.isCurrentEpisode(episode), playback.isActivelyPlaying(episode) else { return false }

        if store.isRemoteControlEnabled {
            return store.isPhoneReachable
                && store.hasRecentPhonePlaybackState
                && store.phonePlaybackState?.isPlaying == true
        }

        return AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty == false
    }

    private func skipBackSystemName(for episode: WatchSyncEpisode) -> String {
        skipBackBehavior(for: episode) == .chapter
            ? "backward.end.fill"
            : "gobackward.\(episode.playbackSettings?.skipBackSeconds ?? store.snapshot.playbackSettings.skipBackSeconds)"
    }

    private func skipForwardSystemName(for episode: WatchSyncEpisode) -> String {
        skipForwardBehavior(for: episode) == .chapter
            ? "forward.end.fill"
            : "goforward.\(episode.playbackSettings?.skipForwardSeconds ?? store.snapshot.playbackSettings.skipForwardSeconds)"
    }

    private func skipBackBehavior(for episode: WatchSyncEpisode) -> WatchSkipButtonBehavior {
        if playback.isCurrentEpisode(episode) {
            return playback.skipBackUsesChapter ? .chapter : .seconds
        }
        guard episode.chapters.isEmpty == false else { return .seconds }
        return episode.playbackSettings?.skipBackBehavior
            ?? store.snapshot.playbackSettings.skipBackBehavior
    }

    private func skipForwardBehavior(for episode: WatchSyncEpisode) -> WatchSkipButtonBehavior {
        if playback.isCurrentEpisode(episode) {
            return playback.skipForwardUsesChapter ? .chapter : .seconds
        }
        guard episode.chapters.isEmpty == false else { return .seconds }
        return episode.playbackSettings?.skipForwardBehavior
            ?? store.snapshot.playbackSettings.skipForwardBehavior
    }

    private func skipBackLabel(for episode: WatchSyncEpisode) -> String {
        switch skipBackBehavior(for: episode) {
        case .chapter:
            "Previous chapter"
        case .seconds:
            "Skip back \(episode.playbackSettings?.skipBackSeconds ?? store.snapshot.playbackSettings.skipBackSeconds) seconds"
        }
    }

    private func skipForwardLabel(for episode: WatchSyncEpisode) -> String {
        switch skipForwardBehavior(for: episode) {
        case .chapter:
            "Next chapter"
        case .seconds:
            "Skip forward \(episode.playbackSettings?.skipForwardSeconds ?? store.snapshot.playbackSettings.skipForwardSeconds) seconds"
        }
    }

    private func skipBackHint(for episode: WatchSyncEpisode) -> String {
        switch skipBackBehavior(for: episode) {
        case .chapter: "Jumps to the start of the previous chapter"
        case .seconds: "Moves playback backward by the configured number of seconds"
        }
    }

    private func skipForwardHint(for episode: WatchSyncEpisode) -> String {
        switch skipForwardBehavior(for: episode) {
        case .chapter: "Skips to the next chapter"
        case .seconds: "Moves playback forward by the configured number of seconds"
        }
    }

    private func skipBackPosition(for episode: WatchSyncEpisode) -> Double {
        guard skipBackBehavior(for: episode) == .chapter else {
            return max(activePosition - Double(episode.playbackSettings?.skipBackSeconds ?? store.snapshot.playbackSettings.skipBackSeconds), 0)
        }
        let reference = max(activePosition - 3, 0)
        return episode.chapters.last(where: { $0.start <= reference })?.start ?? 0
    }

    private func skipForwardPosition(for episode: WatchSyncEpisode) -> Double {
        guard skipForwardBehavior(for: episode) == .chapter else {
            return activePosition + Double(episode.playbackSettings?.skipForwardSeconds ?? store.snapshot.playbackSettings.skipForwardSeconds)
        }
        return episode.chapters.first(where: { $0.start > activePosition + 0.5 })?.start ?? activePosition
    }

}

private struct WatchPlayerVolumeRow: View {
    let canAdjustVolume: Bool
    let unavailableMessage: String
    let origin: WKInterfaceVolumeControl.Origin

    var body: some View {
        Group {
            if canAdjustVolume {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .accessibilityHidden(true)
                    Text("Volume")
                        .font(.footnote.weight(.medium))
                    Spacer(minLength: 4)
                    NativeWatchVolumeControl(origin: origin)
                        .id(origin)
                        .frame(width: 48, height: 32)
                        .accessibilityLabel("Volume")
                        .accessibilityHint("Adjust volume with the Digital Crown")
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Volume", systemImage: "speaker.wave.2.fill")
                        .font(.footnote.weight(.medium))
                        .labelStyle(.titleAndIcon)
                    Text(unavailableMessage)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct NativeWatchVolumeControl: WKInterfaceObjectRepresentable {
    let origin: WKInterfaceVolumeControl.Origin

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: origin)
    }

    func updateWKInterfaceObject(_ object: WKInterfaceVolumeControl, context: Context) {}

    static func dismantleWKInterfaceObject(_ object: WKInterfaceVolumeControl, coordinator: ()) {
        if #available(watchOS 6.0, *) {
            // Return Digital Crown ownership to a containing ScrollView when
            // the volume control leaves the selected source player.
            object.resignFocus()
        }
    }
}

struct WatchAppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.11, blue: 0.17),
                    Color.upNextAccent.opacity(0.34),
                    Color(red: 0.02, green: 0.04, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.upNextAccent.opacity(0.24))
                .frame(width: 96, height: 96)
                .blur(radius: 16)
                .offset(x: 38, y: -58)

            Circle()
                .fill(Color.upNextAccent.opacity(0.16))
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
                    .stroke(Color.upNextAccent.opacity(0.18), lineWidth: 1)
            )
    }
}

struct WatchArtworkView: View {
    @EnvironmentObject private var store: WatchSyncStore
    let url: URL?
    let title: String
    @State private var artworkImage: UIImage?
   

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.upNextAccent,
                                Color.upNextAccent.opacity(0.54)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if url != nil {
                    if let artworkImage {
                        Image(uiImage: artworkImage)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else {
                        WatchArtworkPlaceholder(title: title)
                    }
                } else {
                    WatchArtworkPlaceholder(title: title)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .task(id: url) {
            guard let url else {
                artworkImage = nil
                return
            }
            do {
                let (data, _) = try await WatchNetworkURLPolicy.data(
                    from: url,
                    enabled: store.snapshot.networkTrackingProtectionEnabled
                )
                guard Task.isCancelled == false else { return }
                artworkImage = UIImage(data: data)
            } catch {
                artworkImage = nil
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }
}

private struct WatchArtworkPlaceholder: View {
    let title: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {


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
                            colors: [Color.upNextAccent, Color.upNextAccent.opacity(0.62)],
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
                                colors: [Color.upNextAccent, Color.upNextAccent.opacity(0.66)],
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
                        .fill(Color.upNextAccent.opacity(0.18))
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

#if DEBUG
#Preview("Watch Player") {
    let store = WatchSyncStore.preview()
    let playback = WatchPlaybackController()
    playback.attach(store: store)

    return NavigationStack {
        WatchPlayerView(episodeID: WatchPreviewData.playlist[0].id)
            .environmentObject(store)
            .environmentObject(playback)
    }
}

#Preview("Watch Player Missing Episode") {
    let store = WatchSyncStore.preview()
    let playback = WatchPlaybackController()
    playback.attach(store: store)

    return WatchPlayerView(episodeID: "missing-preview-episode")
        .environmentObject(store)
        .environmentObject(playback)
}

#Preview("Watch Components") {
    let store = WatchSyncStore.preview()
    VStack(spacing: 12) {
        WatchArtworkView(url: nil, title: "Designing a Tiny Podcast App")
            .frame(width: 120, height: 120)

        WatchPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Progress")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                WatchProgressBar(progress: 0.64)
            }
        }
    }
    .environmentObject(store)
    .padding()
    .background(WatchAppBackground())
}
#endif
