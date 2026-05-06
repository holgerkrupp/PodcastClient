import SwiftUI

struct AppLaunchContainerView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let content: Content

    @State private var didStartSequence = false
    @State private var isLaunchVisible = true
    @State private var isLaunchFinishing = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .allowsHitTesting(!isLaunchVisible)

            if isLaunchVisible {
                AnimatedLaunchView(isFinishing: isLaunchFinishing)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            guard !didStartSequence else { return }
            didStartSequence = true
            await runLaunchSequence()
        }
    }

    @MainActor
    private func runLaunchSequence() async {
        if reduceMotion {
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.easeOut(duration: 0.18)) {
                isLaunchVisible = false
            }
            return
        }

        try? await Task.sleep(for: .milliseconds(360))

        withAnimation(.easeInOut(duration: 0.95)) {
            isLaunchFinishing = true
        }

        try? await Task.sleep(for: .milliseconds(980))

        withAnimation(.easeOut(duration: 0.18)) {
            isLaunchVisible = false
        }
    }
}

struct AnimatedLaunchView: View {
    let isFinishing: Bool

    private let stripeColors: [Color] = [
        Color(.displayP3, red: 0.4685, green: 0.7231, blue: 0.3381, opacity: 1),
        Color(.displayP3, red: 0.9526, green: 0.7310, blue: 0.2930, opacity: 1),
        Color(.displayP3, red: 0.9033, green: 0.5332, blue: 0.2329, opacity: 1),
        Color(.displayP3, red: 0.8135, green: 0.2847, blue: 0.2712, opacity: 1),
        Color(.displayP3, red: 0.5425, green: 0.2603, blue: 0.5791, opacity: 1),
        Color(.displayP3, red: 0.2730, green: 0.6084, blue: 0.8413, opacity: 1)
    ]

    var body: some View {
        GeometryReader { geometry in
            let layout = LaunchLayout(size: geometry.size)

            ZStack {
                LaunchBarsCurtainView(
                    layout: layout,
                    colors: stripeColors,
                    isFinishing: isFinishing
                )

                Image("LaunchMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: layout.launchMarkWidth)
                    .shadow(color: Color.white.opacity(0.18), radius: 8, x: 0, y: 0)
                    .shadow(color: Color.black.opacity(0.22), radius: 22, x: 0, y: 12)
                    .opacity(isFinishing ? 0 : 1)
                    .scaleEffect(isFinishing ? 0.96 : 1)
                    .animation(.easeOut(duration: 0.24), value: isFinishing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

private struct LaunchLayout {
    let size: CGSize

    var launchMarkWidth: CGFloat {
        min(size.width * 0.28, 140)
    }
}

private struct LaunchBarsCurtainView: View {
    let layout: LaunchLayout
    let colors: [Color]
    let isFinishing: Bool

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(1), color],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                /*
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.14))
                            .frame(height: max(1, bandHeight(for: index) * 0.08))
                    }*/
                    .frame(width: layout.size.width, height: bandHeight(for: index))
                    .offset(y: bandOrigin(for: index) + travelOffset(for: index))
                    .shadow(color: color.opacity(0.14), radius: 12, x: 0, y: 6)
                    .animation(
                        .easeInOut(duration: 0.72).delay(Double(index) * 0.06),
                        value: isFinishing
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private func bandHeight(for index: Int) -> CGFloat {
        bandOrigin(for: index + 1) - bandOrigin(for: index)
    }

    private func bandOrigin(for index: Int) -> CGFloat {
        floor(CGFloat(index) * layout.size.height / CGFloat(colors.count))
    }

    private func travelOffset(for index: Int) -> CGFloat {
        guard isFinishing else { return 0 }
        return -layout.size.height - CGFloat(index) * 18
    }
}

#Preview {
    AnimatedLaunchView(isFinishing: false)
}
