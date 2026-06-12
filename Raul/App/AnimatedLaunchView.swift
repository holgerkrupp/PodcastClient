import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ModelContainerLaunchView: View {
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        ZStack {
            AnimatedLaunchView(isFinishing: false)

            if let errorMessage {
                VStack(spacing: 12) {
                    Text("Up Next could not open its library.")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Try Again", action: retry)
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding()
            }
        }
    }
}

struct AppLaunchContainerView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let content: Content

    @State private var isLaunchVisible = true

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content

            if isLaunchVisible {
                CompositorLaunchView(reduceMotion: reduceMotion) {
                    isLaunchVisible = false
                }
                    .transition(.opacity)
                    .zIndex(1)
                    .allowsHitTesting(false)
            }
        }
    }
}

#if canImport(UIKit)
private struct CompositorLaunchView: UIViewRepresentable {
    let reduceMotion: Bool
    let completion: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIView(context: Context) -> LaunchCurtainUIView {
        let view = LaunchCurtainUIView(
            colors: AnimatedLaunchView.activeStripeColors.map(UIColor.init),
            reduceMotion: reduceMotion
        )
        view.animationDidComplete = context.coordinator.complete
        return view
    }

    func updateUIView(_ uiView: LaunchCurtainUIView, context: Context) {}

    final class Coordinator {
        private var didComplete = false
        private let completion: () -> Void

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }

        func complete() {
            guard !didComplete else { return }
            didComplete = true
            completion()
        }
    }
}

private final class LaunchCurtainUIView: UIView, CAAnimationDelegate {
    var animationDidComplete: (() -> Void)?

    private let colors: [UIColor]
    private let reduceMotion: Bool
    private var bandLayers: [CALayer] = []
    private let markLayer = CALayer()
    private var didStart = false

    init(colors: [UIColor], reduceMotion: Bool) {
        self.colors = colors
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didStart, bounds.width > 0, bounds.height > 0 else { return }
        didStart = true
        buildLayers()
        startAnimation()
    }

    private func buildLayers() {
        let bandHeight = bounds.height / CGFloat(colors.count)

        for (index, color) in colors.enumerated() {
            let band = CALayer()
            let minY = floor(CGFloat(index) * bandHeight)
            let maxY = index == colors.count - 1
                ? bounds.height
                : floor(CGFloat(index + 1) * bandHeight)
            band.frame = CGRect(x: 0, y: minY, width: bounds.width, height: maxY - minY)
            band.backgroundColor = color.cgColor
            layer.addSublayer(band)
            bandLayers.append(band)
        }

        guard let image = UIImage(named: "LaunchMark") else { return }
        let markWidth = min(bounds.width * 0.28, 140)
        let markHeight = markWidth * image.size.height / image.size.width
        markLayer.contents = image.cgImage
        markLayer.contentsGravity = .resizeAspect
        markLayer.contentsScale = image.scale
        markLayer.frame = CGRect(
            x: bounds.midX - markWidth / 2,
            y: bounds.midY - markHeight / 2,
            width: markWidth,
            height: markHeight
        )
        layer.addSublayer(markLayer)
    }

    private func startAnimation() {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)

        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.16
            fade.beginTime = now
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.delegate = self
            layer.opacity = 0
            layer.add(fade, forKey: "launchFade")
            return
        }

        let duration: CFTimeInterval = 0.9
        let stagger: CFTimeInterval = 0.055

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, band) in bandLayers.enumerated() {
            let travel = -bounds.height - CGFloat(index) * 18
            band.transform = CATransform3DMakeTranslation(0, travel, 0)

            let animation = CABasicAnimation(keyPath: "transform.translation.y")
            animation.fromValue = 0
            animation.toValue = travel
            animation.duration = duration
            animation.beginTime = now + Double(index) * stagger
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if index == bandLayers.count - 1 {
                animation.delegate = self
            }
            band.add(animation, forKey: "launchCurtain")
        }

        markLayer.opacity = 0
        markLayer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        CATransaction.commit()

        let markFade = CABasicAnimation(keyPath: "opacity")
        markFade.fromValue = 1
        markFade.toValue = 0
        markFade.duration = 0.16
        markFade.beginTime = now
        markFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        markLayer.add(markFade, forKey: "launchMarkFade")
    }

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        Task { @MainActor [weak self] in
            self?.animationDidComplete?()
        }
    }
}
#else
private struct CompositorLaunchView: View {
    let reduceMotion: Bool
    let completion: () -> Void

    @State private var isFinishing = false

    var body: some View {
        AnimatedLaunchView(isFinishing: isFinishing)
            .task {
                isFinishing = true
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 160 : 1_200))
                completion()
            }
    }
}
#endif

struct AnimatedLaunchView: View {
    let isFinishing: Bool

    // Your default 6-color palette fallback
    private static let defaultStripeColors: [Color] = [
        Color(.displayP3, red: 0.4685, green: 0.7231, blue: 0.3381, opacity: 1),
        Color(.displayP3, red: 0.9526, green: 0.7310, blue: 0.2930, opacity: 1),
        Color(.displayP3, red: 0.9033, green: 0.5332, blue: 0.2329, opacity: 1),
        Color(.displayP3, red: 0.8135, green: 0.2847, blue: 0.2712, opacity: 1),
        Color(.displayP3, red: 0.5425, green: 0.2603, blue: 0.5791, opacity: 1),
        Color(.displayP3, red: 0.2730, green: 0.6084, blue: 0.8413, opacity: 1)
    ]

    // Dynamically look up colors based on the currently chosen app icon
    fileprivate static var activeStripeColors: [Color] {
        let currentID = AlternateAppIcon.currentIdentifier
        
        // 1. Fallback if it's the primary icon
        if currentID == AlternateAppIcon.primaryID {
            return defaultStripeColors
        }
        
        // 2. Fetch the colors matching the selected icon
        guard let matchingIcon = AlternateAppIcon(id: currentID),
              !matchingIcon.previewColors.isEmpty else {
            return defaultStripeColors
        }
        
        let sourceColors = matchingIcon.previewColors
        
        // 3. If the theme naturally has 4 or more colors, use it exactly as is
        if sourceColors.count >= 4 {
            return sourceColors
        }
        
        // 4. If it has fewer than 4 colors, pad it out to exactly 4 by repeating the pattern
        return (0..<4).map { index in
            sourceColors[index % sourceColors.count]
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = LaunchLayout(size: geometry.size)

            ZStack {
                LaunchBarsCurtainView(
                    layout: layout,
                    colors: Self.activeStripeColors,
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
