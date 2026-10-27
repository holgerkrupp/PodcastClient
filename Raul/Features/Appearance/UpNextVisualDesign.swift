import SwiftUI
import ESADesignKit
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum UpNextVisualDesignPreference {
    static let storageKey = "upNext.visualDesign"
    static let artworkBlurLevelKey = "upNext.artworkBackgroundBlurLevel.v1"
    static let uniformColorKey = "upNext.uniformColorRGB"
    static let widgetAppearanceKey = "upNext.widgetAppearance.v1"
    static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    static let defaultDarkRGB = "#1A3B38"
    static let defaultLightRGB = "#D4EDE6"

    static func artworkBlurLevel(for storedValue: Int) -> ESAArtworkBlurLevel {
        ESAArtworkBlurLevel(rawValue: storedValue) ?? .standard
    }

    /// App preferences remain canonical. Migrate the in-progress shared style key once.
    static func appDefaults() -> UserDefaults {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: storageKey) == nil,
           let sharedStyle = UserDefaults(suiteName: appGroupID)?.string(forKey: storageKey) {
            defaults.set(sharedStyle, forKey: storageKey)
        }
        return defaults
    }
    static let whatsNewFeatureVersion = "three-designs-v1"
    static let whatsNewAcknowledgementKey = "upNext.visualDesign.whatsNew.\(whatsNewFeatureVersion)"

    static func displayName(for style: ESAVisualStyle) -> String {
        switch style {
        case .artwork: "Artwork"
        case .adaptiveColor: "Adaptive Color"
        case .uniform: "Uniform"
        }
    }

    static func uniformPalette(for colorScheme: ColorScheme, customRGB: String?, highContrast: Bool = false) -> ESAThemePalette {
        let fallback = colorScheme == .light ? defaultLightRGB : defaultDarkRGB
        let background = color(fromRGB: customRGB) ?? color(fromRGB: fallback)!
        let components = rgbComponents(customRGB.flatMap(validatedRGB) ?? fallback)!
        let luminance = relativeLuminance(components)
        let usesBlack = luminance > 0.179
        let foreground = usesBlack ? Color.black : Color.white
        let separatorOpacity: Double
        if highContrast {
            separatorOpacity = 1
        } else if usesBlack {
            let targetLuminance = max((luminance + 0.05) / 3 - 0.05, 0)
            separatorOpacity = luminance > 0 ? min(max((luminance - targetLuminance) / luminance, 0), 1) : 1
        } else {
            let targetLuminance = min(3 * (luminance + 0.05) - 0.05, 1)
            separatorOpacity = luminance < 1 ? min(max((targetLuminance - luminance) / (1 - luminance), 0), 1) : 1
        }
        return ESAThemePalette(
            background: background,
            primaryForeground: foreground,
            secondaryForeground: foreground,
            controlForeground: foreground,
            separator: foreground.opacity(separatorOpacity),
            accent: foreground
        )
    }

    static func validatedRGB(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard text.count == 6, text.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + text.uppercased()
    }

    static func color(fromRGB value: String?) -> Color? {
        guard let rgb = value.flatMap(validatedRGB), let (r, g, b) = rgbComponents(rgb) else { return nil }
        return Color(red: r, green: g, blue: b)
    }

    static func rgbString(from color: Color) -> String? {
        #if canImport(UIKit)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #elseif canImport(AppKit)
        guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        let red = converted.redComponent, green = converted.greenComponent, blue = converted.blueComponent
        #else
        return nil
        #endif
        return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    private static func rgbComponents(_ value: String) -> (Double, Double, Double)? {
        guard let rgb = validatedRGB(value) else { return nil }
        let digits = String(rgb.dropFirst())
        guard let number = UInt32(digits, radix: 16) else { return nil }
        return (Double((number >> 16) & 255) / 255, Double((number >> 8) & 255) / 255, Double(number & 255) / 255)
    }

    private static func relativeLuminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }
}

struct WidgetAppearanceSnapshot: Codable {
    let schemaVersion: Int
    let visualStyle: String
    let uniformColorRGB: String?
    /// Optional for compatibility with snapshots written by older app versions.
    let artworkBlurLevel: Int?
}

@MainActor
enum WidgetAppearancePublisher {
    private static var pendingReload: Task<Void, Never>?

    static func publishAndReloadDebounced() {
        let defaults = UpNextVisualDesignPreference.appDefaults()
        let style = defaults.string(forKey: UpNextVisualDesignPreference.storageKey) ?? ESAVisualStyle.artwork.rawValue
        let rawColor = defaults.string(forKey: UpNextVisualDesignPreference.uniformColorKey)
        let color = UpNextVisualDesignPreference.validatedRGB(rawColor)
        let blur = UpNextVisualDesignPreference.artworkBlurLevel(
            for: defaults.object(forKey: UpNextVisualDesignPreference.artworkBlurLevelKey) as? Int
                ?? ESAArtworkBlurLevel.standard.rawValue
        )
        let snapshot = WidgetAppearanceSnapshot(
            schemaVersion: 1,
            visualStyle: style,
            uniformColorRGB: color,
            artworkBlurLevel: blur.rawValue
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let sharedDefaults = UserDefaults(suiteName: UpNextVisualDesignPreference.appGroupID)
        guard sharedDefaults?.data(forKey: UpNextVisualDesignPreference.widgetAppearanceKey) != data else { return }
        sharedDefaults?.set(data, forKey: UpNextVisualDesignPreference.widgetAppearanceKey)
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard Task.isCancelled == false else { return }
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: "PlayNextQueueWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "UpNextNowPlayingWidget")
            #endif
        }
    }
}

enum UpNextSemanticForegroundRole {
    case primary
    case secondary
    case control
}

private struct UpNextSemanticForeground: ViewModifier {
    @Environment(\.esaThemePalette) private var palette
    let role: UpNextSemanticForegroundRole

    private var color: Color {
        switch role {
        case .primary: palette.primaryForeground
        case .secondary: palette.secondaryForeground
        case .control: palette.controlForeground
        }
    }

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }
}

extension View {
    func esaForeground(_ role: UpNextSemanticForegroundRole) -> some View {
        modifier(UpNextSemanticForeground(role: role))
    }

    func upNextVisualDesignRoot() -> some View {
        modifier(UpNextVisualDesignRootModifier())
    }
}

private struct UpNextVisualDesignRootModifier: ViewModifier {
    @AppStorage(UpNextVisualDesignPreference.storageKey, store: UpNextVisualDesignPreference.appDefaults())
    private var storedStyle = ESAVisualStyle.artwork.rawValue
    @AppStorage(UpNextVisualDesignPreference.uniformColorKey, store: UpNextVisualDesignPreference.appDefaults())
    private var customRGB = ""
    @AppStorage(UpNextVisualDesignPreference.artworkBlurLevelKey, store: UpNextVisualDesignPreference.appDefaults())
    private var storedArtworkBlurLevel = ESAArtworkBlurLevel.standard.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    func body(content: Content) -> some View {
        content.esaVisualStyle(
            ESAVisualStyle(rawValue: storedStyle) ?? .artwork,
            uniformPalette: UpNextVisualDesignPreference.uniformPalette(for: colorScheme, customRGB: customRGB, highContrast: accessibilityContrast == .increased)
        )
        .esaArtworkBlurLevel(UpNextVisualDesignPreference.artworkBlurLevel(for: storedArtworkBlurLevel))
        .task { WidgetAppearancePublisher.publishAndReloadDebounced() }
        .onChange(of: storedStyle) { _, _ in WidgetAppearancePublisher.publishAndReloadDebounced() }
        .onChange(of: customRGB) { _, _ in WidgetAppearancePublisher.publishAndReloadDebounced() }
        .onChange(of: storedArtworkBlurLevel) { _, _ in WidgetAppearancePublisher.publishAndReloadDebounced() }
    }
}

struct VisualDesignChooser: View {
    @Binding var selection: ESAVisualStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @AppStorage(UpNextVisualDesignPreference.uniformColorKey, store: UpNextVisualDesignPreference.appDefaults())
    private var customRGB = ""
    @AppStorage(UpNextVisualDesignPreference.artworkBlurLevelKey, store: UpNextVisualDesignPreference.appDefaults())
    private var storedArtworkBlurLevel = ESAArtworkBlurLevel.standard.rawValue
    @State private var previewPodcast: Podcast = {
        let podcast = Podcast(feed: URL(string: "https://example.com/up-next-design-preview.xml")!)
        podcast.title = "Up Next"
        podcast.author = "Your podcasts, your design"
        podcast.desc = "A preview of how podcast artwork and details look in this design."
        podcast.metaData?.isSubscribed = true
        return podcast
    }()
    private let previewArtwork = Image("iconPreviews/AppIcon")
    private let previewArtworkSource = ESAPlatformImage(named: "iconPreviews/AppIcon")
    var explanatoryText: String = "Choose how podcast artwork and colors appear across Up Next. You can change this any time in Appearance settings."

    private let descriptions: [(ESAVisualStyle, String, String)] = [
        (.artwork, "Artwork", "Blurred cover art with a frosted surface."),
        (.adaptiveColor, "Adaptive Color", "A clear, accessible color drawn from each cover."),
        (.uniform, "Uniform", "One calm color palette throughout Up Next.")
    ]

    private var previewPalette: ESAThemePalette {
        UpNextVisualDesignPreference.uniformPalette(
            for: colorScheme,
            customRGB: customRGB,
            highContrast: accessibilityContrast == .increased
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(explanatoryText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(ESAVisualStyle.allCases, id: \.rawValue) { style in
                    let title = descriptions.first(where: { $0.0 == style })?.1 ?? style.rawValue
                    let detail = descriptions.first(where: { $0.0 == style })?.2 ?? ""
                    Button {
                        if reduceMotion {
                            selection = style
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) { selection = style }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            PodcastRowView(
                                podcast: previewPodcast,
                                previewArtwork: previewArtwork,
                                previewArtworkSource: previewArtworkSource.map(ESAImageSource.platformImage)
                            )
                            .esaVisualStyle(style, uniformPalette: previewPalette)
                            .clipShape(RoundedRectangle(cornerRadius: 14))

                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title).font(.headline)
                                    Text(detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: selection == style ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(selection == style ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(12)
                        .background(selection == style ? Color.accentColor.opacity(0.10) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(selection == style ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selection == style ? 2 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(title). \(detail)")
                    .accessibilityAddTraits(selection == style ? [.isSelected] : [])

                    if style == .uniform && selection == .uniform {
                        uniformColorControls
                    }
                    if style == .artwork && selection == .artwork {
                        artworkBlurControls
                    }
                }
            }
            .padding()
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("visualDesignChooser")
        .onChange(of: customRGB) { _, _ in WidgetAppearancePublisher.publishAndReloadDebounced() }
        .onChange(of: storedArtworkBlurLevel) { _, _ in WidgetAppearancePublisher.publishAndReloadDebounced() }
    }

    private var uniformColorControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColorPicker("Uniform color", selection: uniformColorBinding, supportsOpacity: false)
                .accessibilityHint("Choose the background color used by the Uniform design and its widgets.")
            HStack(spacing: 8) {
                Circle()
                    .fill(UpNextVisualDesignPreference.color(fromRGB: customRGB) ?? UpNextVisualDesignPreference.uniformPalette(for: colorScheme, customRGB: nil).background)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                    .accessibilityLabel("Selected Uniform color")
                Text(customRGB.isEmpty ? "Default teal" : (UpNextVisualDesignPreference.validatedRGB(customRGB) ?? "Default teal"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to default") { customRGB = "" }
                    .disabled(customRGB.isEmpty)
            }
        }
        .padding(.leading, 12)
        .padding(.bottom, 4)
    }

    private var artworkBlurControls: some View {
        let level = UpNextVisualDesignPreference.artworkBlurLevel(for: storedArtworkBlurLevel)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Background blur")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(level.settingsLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text("Less")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(level.rawValue) },
                        set: { storedArtworkBlurLevel = min(max(Int($0.rounded()), 0), 4) }
                    ),
                    in: Double(ESAArtworkBlurLevel.minimal.rawValue)...Double(ESAArtworkBlurLevel.maximum.rawValue),
                    step: 1
                )
                .accessibilityLabel("Artwork background blur")
                .accessibilityValue(level.settingsLabel)
                .accessibilityHint("Adjusts blurred artwork and frosted backgrounds on podcast and episode views and Home Screen widgets.")
                Text("More")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Changes apply to the Artwork design on this device, including widgets. Widget updates depend on the system. Standard preserves the original in-app blur.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Reset to Standard") {
                storedArtworkBlurLevel = ESAArtworkBlurLevel.standard.rawValue
            }
            .disabled(level == .standard)
        }
        .padding(.leading, 12)
        .padding(.bottom, 4)
    }

    private var uniformColorBinding: Binding<Color> {
        Binding(
            get: { UpNextVisualDesignPreference.color(fromRGB: customRGB) ?? UpNextVisualDesignPreference.color(fromRGB: colorScheme == .light ? UpNextVisualDesignPreference.defaultLightRGB : UpNextVisualDesignPreference.defaultDarkRGB)! },
            set: { customRGB = UpNextVisualDesignPreference.rgbString(from: $0) ?? customRGB }
        )
    }
}

private extension ESAArtworkBlurLevel {
    var settingsLabel: String {
        switch self {
        case .minimal: "Minimal"
        case .soft: "Soft"
        case .standard: "Standard"
        case .strong: "Strong"
        case .maximum: "Maximum"
        }
    }
}

struct VisualDesignSettingsView: View {
    @AppStorage(UpNextVisualDesignPreference.storageKey, store: UpNextVisualDesignPreference.appDefaults())
    private var storedStyle = ESAVisualStyle.artwork.rawValue
    private var selection: Binding<ESAVisualStyle> {
        Binding(
            get: { ESAVisualStyle(rawValue: storedStyle) ?? .artwork },
            set: { storedStyle = $0.rawValue }
        )
    }

    var body: some View {
        VisualDesignChooser(selection: selection)
            .navigationTitle("Design")
            .platformInlineNavigationTitle()
    }
}

struct VisualDesignWhatsNewSheet: View {
    @AppStorage(UpNextVisualDesignPreference.storageKey, store: UpNextVisualDesignPreference.appDefaults())
    private var storedStyle = ESAVisualStyle.artwork.rawValue
    @State private var selection: ESAVisualStyle = .artwork
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            VisualDesignChooser(
                selection: $selection,
                explanatoryText: "Up Next now offers three accessible designs. Choose the look that works best for you. You can change it later in Appearance settings."
            )
            .navigationTitle("What's New")
            .platformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        storedStyle = selection.rawValue
                        onContinue()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
