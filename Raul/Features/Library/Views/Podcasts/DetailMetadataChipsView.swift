import SwiftUI

struct PodcastDetailMetadataChipsView: View {
    let podcast: Podcast

    var hasContent: Bool {
        podcast.language?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        FlowRows(spacing: 8) {
            if let language = podcast.language?.trimmingCharacters(in: .whitespacesAndNewlines),
               language.isEmpty == false {
                DetailMetadataChip(iconName: "globe", text: language)
            }
        }
    }
}

private struct DetailMetadataChip: View {
    let iconName: String
    let text: String
    let destination: URL?

    init(iconName: String, text: String, destination: URL? = nil) {
        self.iconName = iconName
        self.text = text
        self.destination = destination
    }

    var body: some View {
        if let destination {
            Link(destination: destination) {
                content(showsLinkIcon: iconName != "link")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(text), opens link")
        } else {
            content(showsLinkIcon: false)
        }
    }

    private func content(showsLinkIcon: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if showsLinkIcon {
                Image(systemName: "link")
                    .imageScale(.small)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
