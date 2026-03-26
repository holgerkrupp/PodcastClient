import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

    /// The "AccentColor" asset catalog color resource.
    static let accent = DeveloperToolsSupport.ColorResource(name: "AccentColor", bundle: resourceBundle)

    /// The "backgroundColor" asset catalog color resource.
    static let background = DeveloperToolsSupport.ColorResource(name: "backgroundColor", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "custom.cloud.badge.play" asset catalog image resource.
    static let customCloudBadgePlay = DeveloperToolsSupport.ImageResource(name: "custom.cloud.badge.play", bundle: resourceBundle)

    /// The "custom.play.circle.badge.checkmark" asset catalog image resource.
    static let customPlayCircleBadgeCheckmark = DeveloperToolsSupport.ImageResource(name: "custom.play.circle.badge.checkmark", bundle: resourceBundle)

    /// The "custom.quote.bubble.rectangle.portrait" asset catalog image resource.
    static let customQuoteBubbleRectanglePortrait = DeveloperToolsSupport.ImageResource(name: "custom.quote.bubble.rectangle.portrait", bundle: resourceBundle)

    /// The "custom.quote.bubble.slash" asset catalog image resource.
    static let customQuoteBubbleSlash = DeveloperToolsSupport.ImageResource(name: "custom.quote.bubble.slash", bundle: resourceBundle)

    /// The "extremelysuccessfullogo" asset catalog image resource.
    static let extremelysuccessfullogo = DeveloperToolsSupport.ImageResource(name: "extremelysuccessfullogo", bundle: resourceBundle)

    /// The "githublogo" asset catalog image resource.
    static let githublogo = DeveloperToolsSupport.ImageResource(name: "githublogo", bundle: resourceBundle)

    /// The "mastodon" asset catalog image resource.
    static let mastodon = DeveloperToolsSupport.ImageResource(name: "mastodon", bundle: resourceBundle)

    /// The "mastodon.clean" asset catalog image resource.
    static let mastodonClean = DeveloperToolsSupport.ImageResource(name: "mastodon.clean", bundle: resourceBundle)

    /// The "mastodon.clean.fill" asset catalog image resource.
    static let mastodonCleanFill = DeveloperToolsSupport.ImageResource(name: "mastodon.clean.fill", bundle: resourceBundle)

    /// The "mastodon.fill" asset catalog image resource.
    static let mastodonFill = DeveloperToolsSupport.ImageResource(name: "mastodon.fill", bundle: resourceBundle)

}

// MARK: - Color Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

    /// The "AccentColor" asset catalog color.
    static var accent: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .accent)
#else
        .init()
#endif
    }

    /// The "backgroundColor" asset catalog color.
    static var background: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .background)
#else
        .init()
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    /// The "AccentColor" asset catalog color.
    static var accent: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .accent)
#else
        .init()
#endif
    }

    /// The "backgroundColor" asset catalog color.
    static var background: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .background)
#else
        .init()
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    /// The "AccentColor" asset catalog color.
    static var accent: SwiftUI.Color { .init(.accent) }

    /// The "backgroundColor" asset catalog color.
    static var background: SwiftUI.Color { .init(.background) }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    /// The "AccentColor" asset catalog color.
    static var accent: SwiftUI.Color { .init(.accent) }

    /// The "backgroundColor" asset catalog color.
    static var background: SwiftUI.Color { .init(.background) }

}
#endif

// MARK: - Image Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    /// The "custom.cloud.badge.play" asset catalog image.
    static var customCloudBadgePlay: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .customCloudBadgePlay)
#else
        .init()
#endif
    }

    /// The "custom.play.circle.badge.checkmark" asset catalog image.
    static var customPlayCircleBadgeCheckmark: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .customPlayCircleBadgeCheckmark)
#else
        .init()
#endif
    }

    /// The "custom.quote.bubble.rectangle.portrait" asset catalog image.
    static var customQuoteBubbleRectanglePortrait: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .customQuoteBubbleRectanglePortrait)
#else
        .init()
#endif
    }

    /// The "custom.quote.bubble.slash" asset catalog image.
    static var customQuoteBubbleSlash: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .customQuoteBubbleSlash)
#else
        .init()
#endif
    }

    /// The "extremelysuccessfullogo" asset catalog image.
    static var extremelysuccessfullogo: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .extremelysuccessfullogo)
#else
        .init()
#endif
    }

    /// The "githublogo" asset catalog image.
    static var githublogo: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .githublogo)
#else
        .init()
#endif
    }

    /// The "mastodon" asset catalog image.
    static var mastodon: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .mastodon)
#else
        .init()
#endif
    }

    /// The "mastodon.clean" asset catalog image.
    static var mastodonClean: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .mastodonClean)
#else
        .init()
#endif
    }

    /// The "mastodon.clean.fill" asset catalog image.
    static var mastodonCleanFill: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .mastodonCleanFill)
#else
        .init()
#endif
    }

    /// The "mastodon.fill" asset catalog image.
    static var mastodonFill: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .mastodonFill)
#else
        .init()
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    /// The "custom.cloud.badge.play" asset catalog image.
    static var customCloudBadgePlay: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .customCloudBadgePlay)
#else
        .init()
#endif
    }

    /// The "custom.play.circle.badge.checkmark" asset catalog image.
    static var customPlayCircleBadgeCheckmark: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .customPlayCircleBadgeCheckmark)
#else
        .init()
#endif
    }

    /// The "custom.quote.bubble.rectangle.portrait" asset catalog image.
    static var customQuoteBubbleRectanglePortrait: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .customQuoteBubbleRectanglePortrait)
#else
        .init()
#endif
    }

    /// The "custom.quote.bubble.slash" asset catalog image.
    static var customQuoteBubbleSlash: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .customQuoteBubbleSlash)
#else
        .init()
#endif
    }

    /// The "extremelysuccessfullogo" asset catalog image.
    static var extremelysuccessfullogo: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .extremelysuccessfullogo)
#else
        .init()
#endif
    }

    /// The "githublogo" asset catalog image.
    static var githublogo: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .githublogo)
#else
        .init()
#endif
    }

    /// The "mastodon" asset catalog image.
    static var mastodon: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .mastodon)
#else
        .init()
#endif
    }

    /// The "mastodon.clean" asset catalog image.
    static var mastodonClean: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .mastodonClean)
#else
        .init()
#endif
    }

    /// The "mastodon.clean.fill" asset catalog image.
    static var mastodonCleanFill: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .mastodonCleanFill)
#else
        .init()
#endif
    }

    /// The "mastodon.fill" asset catalog image.
    static var mastodonFill: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .mastodonFill)
#else
        .init()
#endif
    }

}
#endif

// MARK: - Thinnable Asset Support -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ColorResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if AppKit.NSColor(named: NSColor.Name(thinnableName), bundle: bundle) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIColor(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !targetEnvironment(macCatalyst)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}
#endif

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ImageResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if bundle.image(forResource: NSImage.Name(thinnableName)) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIImage(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !targetEnvironment(macCatalyst)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

