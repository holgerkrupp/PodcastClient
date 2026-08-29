import SwiftData
import SwiftUI

struct CompactAppShell: View {
    @Bindable var navigation: AppNavigationModel
    let inboxCount: Int
    let playlistTitle: String
    let playlistSymbolName: String
    @Binding var search: String

    var body: some View {
        TabView(selection: $navigation.selectedSection) {
            Tab(LocalizedStringKey(playlistTitle), systemImage: playlistSymbolName, value: AppSection.queue) {
                AppSectionHost(section: .queue, navigation: navigation, search: $search)
            }

            Tab("Inbox", systemImage: AppSection.inbox.symbolName, value: AppSection.inbox) {
                AppSectionHost(section: .inbox, navigation: navigation, search: $search)
            }
            .badge(inboxCount)

            Tab("Library", systemImage: AppSection.library.symbolName, value: AppSection.library) {
                AppSectionHost(section: .library, navigation: navigation, search: $search)
            }

            Tab("Add", systemImage: "plus", value: AppSection.search, role: .search) {
                AppSectionHost(section: .search, navigation: navigation, search: $search)
            }
        }
        .platformPlayerAccessory()
    }
}

struct SidebarAppShell: View {
    @Bindable var navigation: AppNavigationModel
    let inboxCount: Int
    @Binding var search: String

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: sidebarSelection) {
                    ForEach(AppSectionGroup.allCases) { group in
                        Section(group.rawValue) {
                            ForEach(sections(in: group)) { section in
                                sidebarRow(for: section)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(maxHeight: .infinity)

                PersistentMiniPlayer()
            }
            .navigationTitle("Up Next")
        } detail: {
            AppSectionHost(
                section: navigation.selectedSection,
                navigation: navigation,
                search: $search
            )
        }
    }

    private func sections(in group: AppSectionGroup) -> [AppSection] {
        AppSection.allCases.filter { $0.sidebarGroup == group }
    }

    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { navigation.selectedSection },
            set: { newValue in
                if let newValue {
                    navigation.selectedSection = newValue
                }
            }
        )
    }

    private func sidebarRow(for section: AppSection) -> some View {
        AppSidebarRow(section: section, badge: section == .inbox ? inboxCount : nil)
            .tag(section)
    }
}

private struct AppSidebarRow: View {
    let section: AppSection
    let badge: Int?

    var body: some View {
        HStack {
            Label(section.sidebarTitle, systemImage: section.symbolName)
            Spacer()
            if let badge, badge > 0 {
                Text(badge, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let badge, badge > 0 else { return section.sidebarTitle }
        return "\(section.sidebarTitle), \(badge) items"
    }
}

struct AppSectionHost: View {
    let section: AppSection
    @Bindable var navigation: AppNavigationModel
    @Binding var search: String

    var body: some View {
        NavigationStack(path: navigation.pathBinding(for: section)) {
            AppSectionDestinationView(
                section: section,
                requestedPlaylistEpisodeURL: $navigation.requestedPlaylistEpisodeURL,
                search: $search
            )
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .episode(let url):
                        RequestedEpisodeDestination(url: url)
                    }
                }
        }
    }
}

private struct AppSectionDestinationView: View {
    let section: AppSection
    @Binding var requestedPlaylistEpisodeURL: URL?
    @Binding var search: String

    var body: some View {
        switch section {
        case .queue:
            PlaylistView(requestedEpisodeURL: $requestedPlaylistEpisodeURL)
        case .inbox:
            InboxView()
        case .library:
            LibraryView()
        case .search:
            AddPodcastView(search: $search)
                .searchable(text: $search, prompt: "URL or Search")
        case .downloads:
            DownloadedEpisodesView()
        case .bookmarks:
            BookmarkListView()
        case .history:
            StatisticsView()
        }
    }
}

private struct RequestedEpisodeDestination: View {
    let url: URL
    @Environment(\.modelContext) private var modelContext
    @State private var episode: Episode?

    var body: some View {
        Group {
            if let episode {
                EpisodeDetailView(episode: episode)
            } else {
                ContentUnavailableView(
                    "Episode Not Found",
                    systemImage: "exclamationmark.magnifyingglass"
                )
            }
        }
        .task(id: url) {
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.url == url }
            )
            episode = try? modelContext.fetch(descriptor).first
        }
    }
}

private struct PersistentMiniPlayer: View {
    @Bindable private var player = Player.shared

    var body: some View {
        if player.currentEpisode != nil {
            VStack(spacing: 0) {
                Divider()
                PlayerTabBarView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .clipped()
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(.bar)
        }
    }
}
