import SwiftUI
import ESADesignKit

enum UpNextVisualDesignPreference {
    static let storageKey = "upNext.visualDesign"
    static let whatsNewFeatureVersion = "three-designs-v1"
    static let whatsNewAcknowledgementKey = "upNext.visualDesign.whatsNew.\(whatsNewFeatureVersion)"

    static func displayName(for style: ESAVisualStyle) -> String {
        switch style {
        case .artwork: "Artwork"
        case .adaptiveColor: "Adaptive Color"
        case .uniform: "Uniform"
        }
    }

    /// A consistent dark teal palette for Up Next's Uniform design.
    static let uniformPalette = ESAThemePalette(
        background: Color(red: 0.10, green: 0.23, blue: 0.22),
        primaryForeground: .white,
        secondaryForeground: Color.white.opacity(0.88),
        controlForeground: .white,
        separator: Color.white.opacity(0.42),
        accent: .mint
    )

    static func uniformPalette(for colorScheme: ColorScheme) -> ESAThemePalette {
        guard colorScheme == .light else { return uniformPalette }
        let foreground = Color(red: 0.08, green: 0.20, blue: 0.19)
        return ESAThemePalette(
            background: Color(red: 0.83, green: 0.93, blue: 0.90),
            primaryForeground: foreground,
            secondaryForeground: foreground.opacity(0.82),
            controlForeground: foreground,
            separator: foreground.opacity(0.35),
            accent: Color(red: 0.04, green: 0.43, blue: 0.37)
        )
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
    @AppStorage(UpNextVisualDesignPreference.storageKey)
    private var storedStyle = ESAVisualStyle.artwork.rawValue
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.esaVisualStyle(
            ESAVisualStyle(rawValue: storedStyle) ?? .artwork,
            uniformPalette: UpNextVisualDesignPreference.uniformPalette(for: colorScheme)
        )
    }
}

struct VisualDesignChooser: View {
    @Binding var selection: ESAVisualStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
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
                            .esaVisualStyle(style, uniformPalette: UpNextVisualDesignPreference.uniformPalette(for: colorScheme))
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
                }
            }
            .padding()
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("visualDesignChooser")
    }
}

struct VisualDesignSettingsView: View {
    @AppStorage(UpNextVisualDesignPreference.storageKey) private var storedStyle = ESAVisualStyle.artwork.rawValue
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
    @AppStorage(UpNextVisualDesignPreference.storageKey) private var storedStyle = ESAVisualStyle.artwork.rawValue
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
