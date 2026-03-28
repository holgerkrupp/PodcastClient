import SwiftUI

struct AppLaunchContainerView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let content: Content

    @State private var didStartSequence = false
    @State private var isContentVisible = false
    @State private var isLaunchVisible = true
    @State private var isLaunchFinishing = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .opacity(isContentVisible ? 1 : 0.001)
                .scaleEffect(isContentVisible || reduceMotion ? 1 : 1.01)
                .blur(radius: isContentVisible || reduceMotion ? 0 : 6)
                .animation(.easeOut(duration: 0.35), value: isContentVisible)

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
            isContentVisible = true
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeOut(duration: 0.18)) {
                isLaunchVisible = false
            }
            return
        }

        try? await Task.sleep(for: .milliseconds(1280))

        withAnimation(.easeOut(duration: 0.25)) {
            isContentVisible = true
        }

        withAnimation(.spring(duration: 0.7, bounce: 0.08)) {
            isLaunchFinishing = true
        }

        try? await Task.sleep(for: .milliseconds(360))

        withAnimation(.easeOut(duration: 0.22)) {
            isLaunchVisible = false
        }
    }
}

struct AnimatedLaunchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isFinishing: Bool

    @State private var hasAppeared = false
    @State private var pulsePlayButton = false

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
            let layout = LaunchLayout(
                size: geometry.size,
                safeTop: geometry.safeAreaInsets.top
            )

            ZStack {
                Color("backgroundColor")
                    .ignoresSafeArea()

                FlowingLaunchBarsView(
                    layout: layout,
                    colors: stripeColors,
                    hasAppeared: hasAppeared,
                    animate: !reduceMotion
                )
                .opacity(isFinishing ? 0 : 1)
                .offset(y: isFinishing ? -28 : 0)

                CenteredPlayButton(
                    size: layout.playButtonSize,
                    shouldPulse: pulsePlayButton && !reduceMotion
                )
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.5)
                .scaleEffect(isFinishing ? 1.08 : (pulsePlayButton && !reduceMotion ? 1.03 : 1))
                .opacity(isFinishing ? 0 : 1)
                .offset(y: isFinishing ? -20 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .onAppear {
            hasAppeared = true
            guard !reduceMotion else { return }

            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulsePlayButton = true
            }
        }
    }
}

private struct LaunchLayout {
    let size: CGSize
    let safeTop: CGFloat

    var barHeight: CGFloat {
        size.height / 6
    }

    var barGap: CGFloat {
        0
    }

    var topInset: CGFloat {
        safeTop + 0
    }

    var playButtonSize: CGSize {
        let width = min(size.width * 0.24, 132)
        return CGSize(width: width, height: width * 1.04)
    }
}

private struct FlowingLaunchBarsView: View {
    let layout: LaunchLayout
    let colors: [Color]
    let hasAppeared: Bool
    let animate: Bool

    private let horizontalInsets: [CGFloat] = [0, 0, 0, 0, 0, 0]
    private let horizontalOffsets: [CGFloat] = [0, 0, 0, 0, 0, 0]

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.98), color.opacity(0.84)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.18), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .frame(height: layout.barHeight)
                    .padding(.horizontal, horizontalInsets[index])
                    .shadow(color: color.opacity(0.18), radius: 18, x: 0, y: 10)
                    .offset(
                        x: horizontalOffsets[index],
                        y: hasAppeared ? settledY(for: index) : startY(for: index)
                    )
                    .animation(
                        animate
                            ? .spring(duration: 0.82, bounce: 0.16)
                                .delay(Double(index) * 0.08)
                            : nil,
                        value: hasAppeared
                    )
                    .opacity(hasAppeared || !animate ? 1 : 0.96)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func settledY(for index: Int) -> CGFloat {
        layout.topInset + CGFloat(index) * (layout.barHeight + layout.barGap)
    }

    private func startY(for index: Int) -> CGFloat {
        layout.size.height + CGFloat(index) * (layout.barHeight * 0.78)
    }
}

private struct CenteredPlayButton: View {
    let size: CGSize
    let shouldPulse: Bool

    var body: some View {
        PlayTriangleShape()
            .fill(Color.white.opacity(0.96))
            .overlay {
                PlayTriangleShape()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.94), Color.white.opacity(0.74)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: Color.white.opacity(0.2), radius: 6, x: -2, y: -2)
            .shadow(color: Color.black.opacity(0.22), radius: 20, x: 0, y: 12)
            .scaleEffect(shouldPulse ? 1.02 : 0.98)
    }
}

private struct PlayTriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let insetX = rect.width * 0.14
        let insetY = rect.height * 0.08

        let start = CGPoint(x: insetX, y: insetY)
        let tip = CGPoint(x: rect.maxX - insetX * 0.6, y: rect.midY)
        let end = CGPoint(x: insetX, y: rect.maxY - insetY)

        path.move(to: start)
        path.addLine(to: tip)
        path.addLine(to: end)
        path.addLine(to: start)
        /*
        path.addQuadCurve(
            to: tip,
            control: CGPoint(x: rect.maxX * 0.78, y: rect.minY + rect.height * 0.08)
        )
        path.addQuadCurve(
            to: end,
            control: CGPoint(x: rect.maxX * 0.80, y: rect.maxY - rect.height * 0.08)
        )
        path.addQuadCurve(
            to: start,
            control: CGPoint(x: rect.minX + rect.width * 0.06, y: rect.midY)
        )
        */
        path.closeSubpath()

        return path
    }
}

#Preview {
    AnimatedLaunchView(isFinishing: false)
}
