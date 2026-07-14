import SwiftUI

enum PlatformSupport {
    static var usesDesktopLayout: Bool {
#if os(macOS) || targetEnvironment(macCatalyst)
        true
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
