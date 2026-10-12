import SwiftUI

struct WidgetPlaybackProgressRing: View {
    let progress: Double
    let isPlaying: Bool
    let size: CGFloat

    private var normalizedProgress: Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.28), lineWidth: 2)

            Circle()
                .trim(from: 0, to: normalizedProgress)
                .stroke(
                    Color.nowPlayingAccent,
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.primary)
                .offset(x: isPlaying ? 0 : size * 0.025)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private extension Color {
    static let nowPlayingAccent = Color("AccentColor")
}
