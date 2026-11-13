import SwiftUI
import SwiftData



struct PeopleView: View {
    let people: [PersonInfo]
    let fallbackAuthor: String?
    let spacing: CGFloat
    let sourceFeedURL: URL?
    @State private var selectedPerson: PersonInfo?

    init(people: [PersonInfo], fallbackAuthor: String? = nil, spacing: CGFloat = 8, sourceFeedURL: URL? = nil) {
        self.people = people
        self.fallbackAuthor = fallbackAuthor
        self.spacing = spacing
        self.sourceFeedURL = sourceFeedURL
    }

    private var displayPeople: [PersonInfo] {
        guard people.isEmpty else {
            return people
        }

        if let fallbackAuthor = fallbackAuthor?.trimmingCharacters(in: .whitespacesAndNewlines),
           fallbackAuthor.isEmpty == false {
            return [PersonInfo(name: fallbackAuthor, role: "author", href: nil, img: nil)]
        }

        return people
    }

    var body: some View {
        Group {
            if !displayPeople.isEmpty {
                FlowRows(spacing: spacing) {
                    ForEach(displayPeople) { person in
                        HStack(spacing: 4) {
                            Button {
                                selectedPerson = person
                            } label: {
                                PersonChip(person: person)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Explore other episodes featuring this credited person")

                            if let href = person.href {
                                Link(destination: href) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("Open publisher profile for \(person.name)")
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("People")
                .padding()
            }
        }
        .sheet(item: $selectedPerson) { person in
            PersonEpisodesView(person: person, sourceFeedURL: sourceFeedURL)
        }
    }
}

enum PersonCreditIdentity {
    static func matches(
        _ candidate: PersonInfo,
        reference: String?,
        name: String,
        role: String?,
        feedURL: String?,
        episodeFeedURL: String?
    ) -> Bool {
        let candidateReference = normalizedReference(candidate.href?.absoluteString)
        let selectedReference = normalizedReference(reference)
        if let selectedReference, let candidateReference {
            return selectedReference == candidateReference
        }
        if selectedReference != nil || candidateReference != nil {
            return false
        }

        // A name without a stable publisher reference is only comparable within
        // the same feed and credited role, avoiding collisions across shows.
        guard normalizedFeed(feedURL) != nil,
              normalizedFeed(feedURL) == normalizedFeed(episodeFeedURL),
              normalizedName(candidate.name) == normalizedName(name) else {
            return false
        }
        return normalizedRole(candidate.role) == normalizedRole(role)
    }

    private static func normalizedReference(_ value: String?) -> String? {
        guard let value, var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + path
        return components.string?.lowercased()
    }

    private static func normalizedFeed(_ value: String?) -> String? {
        guard let value, let url = URL(string: value),
              url.user == nil, url.password == nil, url.query == nil else { return nil }
        return normalizedReference(url.absoluteString)
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func normalizedRole(_ value: String?) -> String {
        normalizedName(value ?? "")
    }
}

private struct PersonEpisodesView: View {
    let person: PersonInfo
    let sourceFeedURL: URL?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [Episode] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Section("Publisher-provided credits in your library") {
                    ForEach(Array(episodes.enumerated()), id: \.element.persistentModelID) { index, episode in
                        NavigationLink {
                            EpisodeDetailView(episode: episode)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(episode.title).lineLimit(2)
                                Text(episode.podcast?.title ?? "Unknown podcast")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(
                            EpisodeRowGroupPosition(index: index, count: episodes.count)
                                .backgroundShape
                                .fill(.regularMaterial)
                        )
                    }
                }
            }
            .overlay {
                if isLoading { ProgressView() }
                else if episodes.isEmpty {
                    ContentUnavailableView("No Other Credits Found", systemImage: "person.crop.circle", description: Text("Publisher credits are searched in your library only."))
                }
            }
            .navigationTitle(person.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: person.id) {
            let actor = EpisodeListQueryActor(modelContainer: modelContext.container)
            let ids = (try? await actor.episodeIDsFeaturingPerson(
                reference: person.href?.absoluteString,
                name: person.name,
                role: person.role,
                sourceFeedURL: sourceFeedURL?.absoluteString
            )) ?? []
            guard !Task.isCancelled else { return }
            let models: [PersistentIdentifier: Episode] = modelContext.existingModels(for: ids)
            episodes = ids.compactMap { models[$0] }
            isLoading = false
        }
    }
}

private struct PersonChip: View {
    let person: PersonInfo

    var body: some View {
        HStack(spacing: 6) {
            if let img = person.img {
                ProtectedAsyncImage(url: img) { image in
                    if let image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }

            Text(person.name)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct FlowRows: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let neededWidth = (currentRowWidth == 0 ? 0 : spacing) + size.width
            if currentRowWidth + neededWidth > maxWidth {
                totalHeight += currentRowHeight + (totalHeight == 0 ? 0 : spacing)
                currentRowWidth = size.width
                currentRowHeight = size.height
            } else {
                currentRowWidth += neededWidth
                currentRowHeight = max(currentRowHeight, size.height)
            }
        }
        totalHeight += currentRowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                // wrap to next line
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview("PeopleView - Sample") {
    let people: [PersonInfo] = [
        PersonInfo(name: "Alice Brown", role: "guest", href: URL(string: "https://www.wikipedia/alicebrown"), img: URL(string: "http://example.com/images/alicebrown.jpg")),
        PersonInfo(name: "Bob Smith", role: "host", href: nil, img: nil),
        PersonInfo(name: "Carol" , role: nil, href: URL(string: "https://example.com/carol"), img: nil)
    ]
    return PeopleView(people: people)
        .padding()
}
