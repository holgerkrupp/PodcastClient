import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Codable, Hashable {
    case queue
    case inbox
    case library
    case search
    case downloads
    case bookmarks
    case history

    var id: String { rawValue }

    static let compactSections: [AppSection] = [.queue, .inbox, .library, .search]

    var title: String {
        switch self {
        case .queue: "Queue"
        case .inbox: "Inbox"
        case .library: "Library"
        case .search: "Add"
        case .downloads: "Downloads"
        case .bookmarks: "Bookmarks"
        case .history: "Listening History"
        }
    }

    var sidebarTitle: String {
        switch self {
        case .search: "Search"
        default: title
        }
    }

    var symbolName: String {
        switch self {
        case .queue: "calendar.day.timeline.leading"
        case .inbox: "tray.fill"
        case .library: "books.vertical"
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .bookmarks: "bookmark"
        case .history: "waveform"
        }
    }

    var sidebarGroup: AppSectionGroup {
        switch self {
        case .queue, .inbox:
            .listen
        case .library, .downloads, .bookmarks, .history:
            .library
        case .search:
            .discover
        }
    }
}

enum AppSectionGroup: String, CaseIterable, Identifiable {
    case listen = "Listen"
    case library = "Library"
    case discover = "Discover"

    var id: String { rawValue }
}

enum AppRoute: Hashable {
    case episode(URL)
}

@Observable
@MainActor
final class AppNavigationModel {
    static let defaultSection: AppSection = .queue

    var selectedSection: AppSection
    var requestedPlaylistEpisodeURL: URL?
    var isPlayerPresented = false

    private var paths: [AppSection: NavigationPath] = [:]

    init(selectedSection: AppSection = AppNavigationModel.defaultSection) {
        self.selectedSection = selectedSection
    }

    func pathBinding(for section: AppSection) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[section] ?? NavigationPath() },
            set: {
                SystemPressureGate.shared.noteUserInteraction()
                self.paths[section] = $0
            }
        )
    }

    func select(_ section: AppSection) {
        SystemPressureGate.shared.noteUserInteraction()
        selectedSection = section
    }

    func openPlaylistEpisode(_ url: URL) {
        SystemPressureGate.shared.noteUserInteraction()
        selectedSection = .queue
        requestedPlaylistEpisodeURL = url
    }

    func resetPath(for section: AppSection) {
        paths[section] = NavigationPath()
    }

    static func restoredSection(from rawValue: String?) -> AppSection {
        rawValue.flatMap(AppSection.init(rawValue:)) ?? defaultSection
    }
}

enum AppLink: Equatable {
    case playEpisode(URL)
    case showEpisode(URL, playlistID: String?)
    case importSharedEpisode(URL)
    case selectQueue(playlistID: String?)
    case incomingSubscription(URL)
    case podcastYear(URL)

    @MainActor
    static func parse(_ url: URL) -> AppLink? {
        guard url.scheme?.lowercased() == "upnext" else {
            return IncomingPodcastSubscriptionController.canHandle(url)
                ? .incomingSubscription(url)
                : nil
        }

        if PodcastYearShareCoordinator.isPodcastYearURL(url) {
            return .podcastYear(url)
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let episodeURL = queryItems
            .first(where: { $0.name == "url" })?
            .value
            .flatMap(URL.init(string:))
        let playlistID = queryItems
            .first(where: { $0.name == "playlistID" })?
            .value
            .flatMap { UUID(uuidString: $0) == nil ? nil : $0 }

        switch url.host()?.lowercased() {
        case "playepisode":
            return episodeURL.map(AppLink.playEpisode)
        case "episode":
            return episodeURL.map { .showEpisode($0, playlistID: playlistID) }
        case "shareepisode":
            return episodeURL.map(AppLink.importSharedEpisode)
        default:
            return .selectQueue(playlistID: playlistID)
        }
    }
}

struct OpenPlayerAction {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @MainActor
    func callAsFunction() {
        handler()
    }
}

private struct OpenPlayerActionKey: EnvironmentKey {
    static let defaultValue = OpenPlayerAction {
        Player.shared.isPlayerSheetPresented = true
    }
}

extension EnvironmentValues {
    var openPlayer: OpenPlayerAction {
        get { self[OpenPlayerActionKey.self] }
        set { self[OpenPlayerActionKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    func hostsPlayerPresentation(navigation: AppNavigationModel) -> some View {
#if os(macOS) || targetEnvironment(macCatalyst)
        modifier(MacPlayerPresentationHost(navigation: navigation))
#else
        modifier(IOSPlayerPresentationHost(navigation: navigation))
#endif
    }
}

#if os(macOS) || targetEnvironment(macCatalyst)
private struct MacPlayerPresentationHost: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Bindable var navigation: AppNavigationModel

    func body(content: Content) -> some View {
        content
            .environment(
                \.openPlayer,
                OpenPlayerAction {
                    openWindow(id: AppWindowID.player)
                }
            )
            .onChange(of: Player.shared.isPlayerSheetPresented) { _, isPresented in
                guard isPresented else { return }
                Player.shared.isPlayerSheetPresented = false
                openWindow(id: AppWindowID.player)
            }
    }
}
#else
private struct IOSPlayerPresentationHost: ViewModifier {
    @Bindable var navigation: AppNavigationModel

    func body(content: Content) -> some View {
        content
            .environment(
                \.openPlayer,
                OpenPlayerAction {
                    navigation.isPlayerPresented = true
                }
            )
            .sheet(isPresented: $navigation.isPlayerPresented) {
                PlayerView(fullSize: true)
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: Player.shared.isPlayerSheetPresented) { _, isPresented in
                guard isPresented else { return }
                Player.shared.isPlayerSheetPresented = false
                navigation.isPlayerPresented = true
            }
    }
}
#endif

#if os(macOS) || targetEnvironment(macCatalyst)
struct AppNavigationFocusedValueKey: FocusedValueKey {
    typealias Value = AppNavigationModel
}

extension FocusedValues {
    var appNavigationModel: AppNavigationModel? {
        get { self[AppNavigationFocusedValueKey.self] }
        set { self[AppNavigationFocusedValueKey.self] = newValue }
    }
}
#endif
