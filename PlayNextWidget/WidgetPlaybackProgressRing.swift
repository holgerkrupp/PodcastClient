import SwiftUI

struct WidgetPlaybackControl: View {
    let progress: Double
    let isPlaying: Bool
    let size: CGFloat

    private let gaugeLayoutSize: CGFloat = 44

    private var normalizedProgress: Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }

    var body: some View {
        Gauge(value: normalizedProgress) {
            EmptyView()
        } currentValueLabel: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: gaugeLayoutSize * 0.38, weight: .bold))
                .foregroundStyle(.primary)
                .offset(x: isPlaying ? 0 : size * 0.025)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(Color.nowPlayingAccent)
        .frame(width: gaugeLayoutSize, height: gaugeLayoutSize)
        .scaleEffect(size / gaugeLayoutSize)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private extension Color {
    static let nowPlayingAccent = Color("AccentColor")
}
