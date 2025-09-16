import SwiftUI

struct SocialView: View {
    let socials: [SocialInfo]
    let spacing: CGFloat

    init(socials: [SocialInfo], spacing: CGFloat = 8) {
        self.socials = socials
        self.spacing = spacing
    }

    private var sortedSocials: [SocialInfo] {
        socials.sorted { (a, b) in
            switch (a.priority, b.priority) {
            case let (pa?, pb?):
                return pa < pb
            case (nil, _?):
                return false // items with priority come first
            case (_?, nil):
                return true
            case (nil, nil):
                // stable fallback: by protocol then url
                if a.socialprotocol != b.socialprotocol { return a.socialprotocol < b.socialprotocol }
                return a.url.absoluteString < b.url.absoluteString
            }
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            ForEach(sortedSocials) { info in
                Link(destination: info.url) {
                    HStack(spacing: 4) {
                        Text(info.socialprotocol)
                            .font(.footnote)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                        if let accountId = info.accountId, !accountId.isEmpty {
                            Text(accountId)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Group {
                            if let p = info.priority {
                                Text(String(p))
                                    .font(.caption2)
                                    .padding(4)
                                    .background(Circle().fill(Color.secondary.opacity(0.15)))
                                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
                                    .offset(x: 8, y: -8)
                            }
                        }, alignment: .topTrailing
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Social links")
    }
}

#Preview("SocialView - Sample") {
    let sampleSocials: [SocialInfo] = [
        SocialInfo(url: URL(string: "https://podcastindex.social/web/@dave/108013847520053258")!, socialprotocol: "activitypub", accountId: "@dave", accountURL: URL(string: "https://podcastindex.social/web/@dave"), priority: 1),
        SocialInfo(url: URL(string: "https://example.com/user/123")!, socialprotocol: "mastodon", accountId: "@user", accountURL: URL(string: "https://example.com/@user"), priority: 2),
        SocialInfo(url: URL(string: "https://threads.net/@someone")!, socialprotocol: "threads", accountId: "@someone", accountURL: nil, priority: nil)
    ]
    return SocialView(socials: sampleSocials)
        .padding()
}

#Preview("SocialView - Episode Sample") {
    let episodeSocials: [SocialInfo] = [
        SocialInfo(url: URL(string: "https://twitter.com/episodehost")!, socialprotocol: "twitter", accountId: "@episodehost", accountURL: URL(string: "https://twitter.com/episodehost"), priority: 1),
        SocialInfo(url: URL(string: "https://facebook.com/episodepage")!, socialprotocol: "facebook", accountId: "episodepage", accountURL: URL(string: "https://facebook.com/episodepage"), priority: 3),
        SocialInfo(url: URL(string: "https://instagram.com/episodephotos")!, socialprotocol: "instagram", accountId: "@episodephotos", accountURL: nil, priority: 2)
    ]
    return SocialView(socials: episodeSocials)
        .padding()
}
