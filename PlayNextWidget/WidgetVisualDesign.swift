import SwiftUI
import CoreGraphics
import ESADesignKit
#if canImport(UIKit)
import UIKit
typealias WidgetPlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias WidgetPlatformImage = NSImage
#endif

struct WidgetDesignPalette {
    let background: Color
    let primary: Color
    let secondary: Color
    let control: Color
    let accent: Color
}

private struct WidgetDesignPaletteKey: EnvironmentKey {
    static let defaultValue = WidgetDesignPalette(
        background: WidgetVisualDesign.systemBackground,
        primary: .primary,
        secondary: .secondary,
        control: .primary,
        accent: Color("AccentColor")
    )
}

extension EnvironmentValues {
    var widgetDesignPalette: WidgetDesignPalette {
        get { self[WidgetDesignPaletteKey.self] }
        set { self[WidgetDesignPaletteKey.self] = newValue }
    }
}

enum WidgetVisualDesign {
    static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    static let preferenceKey = "upNext.widgetAppearance.v1"

    private struct AppearanceSnapshot: Decodable {
        let schemaVersion: Int
        let visualStyle: String
        let uniformColorRGB: String?
        /// Missing from older v1 snapshots; use the original 50pt blur.
        let artworkBlurLevel: Int?
    }

    private static var appearance: AppearanceSnapshot? {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: preferenceKey),
              let value = try? JSONDecoder().decode(AppearanceSnapshot.self, from: data),
              value.schemaVersion == 1 else { return nil }
        return value
    }

    static var selectedStyle: String {
        appearance?.visualStyle ?? "artwork"
    }

    static var artworkBlurLevel: ESAArtworkBlurLevel {
        ESAArtworkBlurLevel(rawValue: appearance?.artworkBlurLevel ?? ESAArtworkBlurLevel.standard.rawValue)
            ?? .standard
    }

    static var systemBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        .clear
        #endif
    }

    static func artwork(named fileName: String?) -> WidgetPlatformImage? {
        guard let fileName,
              let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
                .appendingPathComponent(fileName) else { return nil }
        #if canImport(UIKit)
        return UIImage(contentsOfFile: url.path)
        #elseif canImport(AppKit)
        return NSImage(contentsOf: url)
        #else
        return nil
        #endif
    }

    static func palette(
        style: String,
        artwork: WidgetPlatformImage?,
        colorScheme: ColorScheme
    ) -> WidgetDesignPalette {
        switch style {
        case "uniform":
            let fallback = colorScheme == .light ? "#D4EDE6" : "#1A3B38"
            let rgb = Self.validatedRGB(appearance?.uniformColorRGB) ?? fallback
            let components = Self.rgbComponents(rgb)
            let luminance = components.map(Self.relativeLuminance) ?? 0.04
            let foreground: Color = luminance > 0.179 ? .black : .white
            return WidgetDesignPalette(
                background: Self.color(rgb) ?? systemBackground,
                primary: foreground,
                secondary: foreground,
                control: foreground,
                accent: foreground
            )
        case "adaptiveColor":
            return adaptivePalette(for: artwork, colorScheme: colorScheme)
        default:
            return WidgetDesignPalette(
                background: systemBackground,
                primary: .primary,
                secondary: .secondary,
                control: .primary,
                accent: Color("AccentColor")
            )
        }
    }

    private static func validatedRGB(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard text.count == 6, text.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + text.uppercased()
    }

    private static func rgbComponents(_ value: String) -> (Double, Double, Double)? {
        guard let value = validatedRGB(value), let number = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return (Double((number >> 16) & 255) / 255, Double((number >> 8) & 255) / 255, Double(number & 255) / 255)
    }

    private static func relativeLuminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    private static func color(_ value: String) -> Color? {
        guard let (red, green, blue) = rgbComponents(value) else { return nil }
        return Color(red: red, green: green, blue: blue)
    }

    private static func adaptivePalette(for artwork: WidgetPlatformImage?, colorScheme: ColorScheme) -> WidgetDesignPalette {
        let (red, green, blue) = artwork.flatMap(averageColor) ?? (0.16, 0.18, 0.22)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let target: Double
        let foreground: Color
        if colorScheme == .light {
            target = max(luminance, 0.84)
            foreground = .black
        } else {
            target = min(luminance, 0.12)
            foreground = .white
        }

        let blend: Double
        if colorScheme == .light {
            blend = luminance >= 1 ? 0 : min(max((target - luminance) / (1 - luminance), 0), 1)
        } else {
            blend = luminance <= 0 ? 0 : min(max(1 - target / luminance, 0), 1)
        }
        let resolved = Color(
            red: red + ((colorScheme == .light ? 1 : 0) - red) * blend,
            green: green + ((colorScheme == .light ? 1 : 0) - green) * blend,
            blue: blue + ((colorScheme == .light ? 1 : 0) - blue) * blend
        )
        return WidgetDesignPalette(
            background: resolved,
            primary: foreground,
            secondary: foreground.opacity(0.84),
            control: foreground,
            accent: Color("AccentColor")
        )
    }

    private static func averageColor(_ image: WidgetPlatformImage) -> (Double, Double, Double)? {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return nil }
        #elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        return nil
        #endif
        guard let context = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let pixel = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (
            Double(pixel[0]) / 255,
            Double(pixel[1]) / 255,
            Double(pixel[2]) / 255
        )
    }

    static func image(_ image: WidgetPlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #elseif canImport(AppKit)
        Image(nsImage: image)
        #else
        Image(systemName: "waveform")
        #endif
    }
}

private struct WidgetVisualDesignModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let style: String
    let artwork: WidgetPlatformImage?

    private var palette: WidgetDesignPalette {
        WidgetVisualDesign.palette(style: style, artwork: artwork, colorScheme: colorScheme)
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(palette.primary)
            .tint(palette.accent)
            .environment(\.widgetDesignPalette, palette)
    }
}

extension View {
    func widgetVisualDesign(style: String, artwork: WidgetPlatformImage?) -> some View {
        modifier(WidgetVisualDesignModifier(style: style, artwork: artwork))
    }
}

struct WidgetVisualDesignBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let style: String
    let artwork: WidgetPlatformImage?

    private var palette: WidgetDesignPalette {
        WidgetVisualDesign.palette(style: style, artwork: artwork, colorScheme: colorScheme)
    }

    var body: some View {
        if style == "artwork", colorSchemeContrast == .increased || reduceTransparency {
            WidgetVisualDesign.systemBackground
        } else if style == "artwork", let artwork {
            ZStack {
                WidgetVisualDesign.systemBackground
                WidgetVisualDesign.image(artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: WidgetVisualDesign.artworkBlurLevel.fullBackgroundBlurRadius)
                    .opacity(0.5)
                // Match ESADesignKit's frosted artwork surfaces. The unblurred
                // episode covers remain in the foreground widget content.
                Rectangle()
                    .fill(WidgetVisualDesign.artworkBlurLevel.rowMaterial)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else if style == "artwork" {
            WidgetVisualDesign.systemBackground
        } else {
            palette.background
        }
    }
}
