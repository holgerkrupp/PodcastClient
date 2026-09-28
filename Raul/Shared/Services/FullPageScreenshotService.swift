#if os(iOS)
import SwiftUI
import UIKit

/// Adds the full-page screenshot representation to the window scene that
/// contains the view. The anchor is intentionally a UIKit view so it can find
/// the UIScrollView that SwiftUI created for the surrounding timeline.
struct FullPageScreenshotAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> FullPageScreenshotAnchorView {
        FullPageScreenshotAnchorView()
    }

    func updateUIView(_ uiView: FullPageScreenshotAnchorView, context: Context) {}

    static func dismantleUIView(_ uiView: FullPageScreenshotAnchorView, coordinator: ()) {
        uiView.unregisterFromScreenshotService()
    }
}

final class FullPageScreenshotAnchorView: UIView {
    private weak var registeredScene: UIWindowScene?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scene = window?.windowScene {
            registeredScene = scene
            FullPageScreenshotService.shared.register(anchor: self)
        } else {
            FullPageScreenshotService.shared.unregister(
                anchor: self,
                from: registeredScene
            )
            registeredScene = nil
        }
    }

    func unregisterFromScreenshotService() {
        FullPageScreenshotService.shared.unregister(
            anchor: self,
            from: registeredScene
        )
        registeredScene = nil
    }
}

@MainActor
final class FullPageScreenshotService: NSObject {
    static let shared = FullPageScreenshotService()

    private struct WeakAnchor {
        weak var value: FullPageScreenshotAnchorView?
    }

    private var anchorsByScene: [ObjectIdentifier: [WeakAnchor]] = [:]
    private var delegatesByScene: [ObjectIdentifier: SceneScreenshotDelegate] = [:]

    func register(anchor: FullPageScreenshotAnchorView) {
        guard let scene = anchor.window?.windowScene,
              let screenshotService = scene.screenshotService else {
            return
        }

        let sceneID = ObjectIdentifier(scene)
        var anchors = anchorsByScene[sceneID, default: []]
        anchors.removeAll { $0.value == nil || $0.value === anchor }
        anchors.append(WeakAnchor(value: anchor))
        anchorsByScene[sceneID] = anchors

        let delegate = delegatesByScene[sceneID] ?? SceneScreenshotDelegate()
        delegatesByScene[sceneID] = delegate
        screenshotService.delegate = delegate
    }

    func unregister(anchor: FullPageScreenshotAnchorView, from scene: UIWindowScene?) {
        guard let scene else {
            remove(anchor: anchor)
            return
        }

        let sceneID = ObjectIdentifier(scene)
        remove(anchor: anchor, from: sceneID)
        updateDelegate(for: scene, sceneID: sceneID)
    }

    private func remove(anchor: FullPageScreenshotAnchorView, from sceneID: ObjectIdentifier? = nil) {
        let sceneIDs = sceneID.map { [$0] } ?? Array(anchorsByScene.keys)
        for id in sceneIDs {
            anchorsByScene[id]?.removeAll { $0.value == nil || $0.value === anchor }
            if anchorsByScene[id]?.isEmpty == true {
                anchorsByScene[id] = nil
            }
        }
    }

    private func updateDelegate(for scene: UIWindowScene, sceneID: ObjectIdentifier) {
        guard let screenshotService = scene.screenshotService else { return }
        guard let anchors = anchorsByScene[sceneID], anchors.isEmpty == false else {
            if screenshotService.delegate === delegatesByScene[sceneID] {
                screenshotService.delegate = nil
            }
            delegatesByScene[sceneID] = nil
            return
        }

        screenshotService.delegate = delegatesByScene[sceneID] ?? {
            let delegate = SceneScreenshotDelegate()
            delegatesByScene[sceneID] = delegate
            return delegate
        }()
    }

    fileprivate func currentAnchor(for scene: UIWindowScene) -> FullPageScreenshotAnchorView? {
        let sceneID = ObjectIdentifier(scene)
        anchorsByScene[sceneID]?.removeAll { $0.value == nil }
        return anchorsByScene[sceneID]?.last?.value
    }
}

@MainActor
private final class SceneScreenshotDelegate: NSObject, UIScreenshotServiceDelegate {
    func screenshotService(
        _ screenshotService: UIScreenshotService,
        generatePDFRepresentationWithCompletion completionHandler: @escaping (Data?, Int, CGRect) -> Void
    ) {
        guard let scene = screenshotService.windowScene,
              let anchor = FullPageScreenshotService.shared.currentAnchor(for: scene),
              let scrollView = anchor.enclosingScrollView(in: scene) else {
            completionHandler(nil, 0, .zero)
            return
        }

        let result = FullPageScreenshotRenderer.render(scrollView: scrollView)
        completionHandler(result.data, 0, result.visibleRect)
    }
}

private extension UIView {
    func enclosingScrollView(in scene: UIWindowScene) -> UIScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            ancestor = view.superview
        }

        // Some SwiftUI containers place a background representable beside the
        // scroll view rather than inside it. In that case, choose the visible
        // scroll view under the same scene whose viewport contains the anchor.
        guard let window else { return nil }
        let anchorPoint = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: window)
        let candidates = window.allDescendants.compactMap { $0 as? UIScrollView }
            .filter {
                $0.window?.windowScene === scene
                    && $0.isHidden == false
                    && $0.alpha > 0
                    && $0.bounds.height > 0
                    && $0.contentSize.height > $0.bounds.height + 1
            }

        return candidates.max { lhs, rhs in
            score(lhs, for: anchorPoint, in: window) < score(rhs, for: anchorPoint, in: window)
        }
    }

    private func score(_ scrollView: UIScrollView, for point: CGPoint, in window: UIWindow) -> CGFloat {
        let frame = scrollView.convert(scrollView.bounds, to: window)
        let containsPoint: CGFloat = frame.contains(point) ? 1_000_000 : 0
        return containsPoint + frame.intersection(window.bounds).area
    }
}

private extension UIView {
    var allDescendants: [UIView] {
        subviews.flatMap { [$0] + $0.allDescendants }
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

@MainActor
private enum FullPageScreenshotRenderer {
    struct Result {
        let data: Data?
        let visibleRect: CGRect
    }

    static func render(scrollView: UIScrollView) -> Result {
        scrollView.layoutIfNeeded()

        let viewportSize = scrollView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return Result(data: nil, visibleRect: .zero)
        }

        let originalOffset = scrollView.contentOffset
        let originalVerticalIndicator = scrollView.showsVerticalScrollIndicator
        let originalHorizontalIndicator = scrollView.showsHorizontalScrollIndicator
        let insets = scrollView.adjustedContentInset
        let minimumOffsetY = -insets.top
        let maximumOffsetY = max(
            minimumOffsetY,
            scrollView.contentSize.height - viewportSize.height + insets.bottom
        )
        let pageHeight = max(
            viewportSize.height,
            maximumOffsetY - minimumOffsetY + viewportSize.height
        )
        let pageRect = CGRect(
            origin: .zero,
            size: CGSize(width: viewportSize.width, height: pageHeight)
        )

        let currentOffsetY = min(max(originalOffset.y, minimumOffsetY), maximumOffsetY)
        let visibleTop = currentOffsetY - minimumOffsetY
        let visibleRect = CGRect(
            x: originalOffset.x,
            y: pageHeight - visibleTop - viewportSize.height,
            width: viewportSize.width,
            height: viewportSize.height
        )

        defer {
            scrollView.showsVerticalScrollIndicator = originalVerticalIndicator
            scrollView.showsHorizontalScrollIndicator = originalHorizontalIndicator
            scrollView.setContentOffset(originalOffset, animated: false)
            scrollView.layoutIfNeeded()
        }

        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { context in
            context.beginPage()

            var offsetY = minimumOffsetY
            while offsetY <= maximumOffsetY {
                scrollView.setContentOffset(
                    CGPoint(x: originalOffset.x, y: offsetY),
                    animated: false
                )
                scrollView.layoutIfNeeded()
                CATransaction.flush()

                let pageY = offsetY - minimumOffsetY
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0, y: pageY)
                scrollView.drawHierarchy(
                    in: CGRect(origin: .zero, size: viewportSize),
                    afterScreenUpdates: true
                )
                context.cgContext.restoreGState()

                offsetY += viewportSize.height
            }
        }

        return Result(data: data, visibleRect: visibleRect)
    }
}

extension View {
    /// Supplies the iOS screenshot markup UI with the full scrollable content
    /// for this timeline. The anchor should live inside the target ScrollView
    /// or List content whenever possible.
    func fullPageScreenshotSupport() -> some View {
        background(FullPageScreenshotAnchor())
    }
}
#endif

#if !os(iOS)
import SwiftUI

extension View {
    func fullPageScreenshotSupport() -> some View { self }
}
#endif
