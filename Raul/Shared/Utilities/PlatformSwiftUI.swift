import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum PlatformSupport {
    static var usesDesktopLayout: Bool {
#if os(macOS) || targetEnvironment(macCatalyst)
        true
#else
        false
#endif
    }

    @MainActor
    static var isPhone: Bool {
#if os(iOS) && !targetEnvironment(macCatalyst)
        UIDevice.current.userInterfaceIdiom == .phone
#else
        false
#endif
    }
}

extension View {
    func platformInlineNavigationTitle() -> some View {
#if os(iOS)
        return navigationBarTitleDisplayMode(.inline)
#else
        return self
#endif
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
