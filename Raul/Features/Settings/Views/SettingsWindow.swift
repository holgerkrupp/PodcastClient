import SwiftData
import SwiftUI

enum SettingsDestination: String, Codable, Hashable {
    case main
    case playback
}

struct SettingsWindowRequest: Codable, Hashable, Identifiable {
    static let sceneID = "settings"

    let podcastID: PersistentIdentifier?
    var destination: SettingsDestination = .main

    static let global = SettingsWindowRequest(podcastID: nil)

    var id: String {
        let scope = podcastID.map { String(describing: $0) } ?? "global"
        return "\(destination.rawValue)-\(scope)"
    }

    static func podcast(_ podcast: Podcast) -> SettingsWindowRequest {
        SettingsWindowRequest(podcastID: podcast.persistentModelID)
    }

    static func playback(for podcast: Podcast?) -> SettingsWindowRequest {
        SettingsWindowRequest(
            podcastID: podcast?.persistentModelID,
            destination: .playback
        )
    }

    private enum CodingKeys: String, CodingKey {
        case podcastID
        case destination
    }

    init(
        podcastID: PersistentIdentifier?,
        destination: SettingsDestination = .main
    ) {
        self.podcastID = podcastID
        self.destination = destination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        podcastID = try container.decodeIfPresent(PersistentIdentifier.self, forKey: .podcastID)
        destination = try container.decodeIfPresent(SettingsDestination.self, forKey: .destination) ?? .main
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(podcastID, forKey: .podcastID)
        try container.encode(destination, forKey: .destination)
    }
}

struct OpenPodcastSettingsAction {
    fileprivate let handler: @MainActor (SettingsWindowRequest) -> Void

    @MainActor
    func callAsFunction(_ request: SettingsWindowRequest = .global) {
        handler(request)
    }
}

private struct OpenPodcastSettingsKey: EnvironmentKey {
    static let defaultValue = OpenPodcastSettingsAction { _ in }
}

extension EnvironmentValues {
    var openPodcastSettings: OpenPodcastSettingsAction {
        get { self[OpenPodcastSettingsKey.self] }
        set { self[OpenPodcastSettingsKey.self] = newValue }
    }
}

struct SettingsWindowContent: View {
    @Environment(\.modelContext) private var modelContext

    let request: SettingsWindowRequest
    var onOpenAllSettings: (() -> Void)?

    var body: some View {
        PodcastSettingsView(
            podcastID: request.podcastID,
            modelContainer: modelContext.container,
            embedInNavigationStack: true,
            destination: request.destination,
            onOpenAllSettings: onOpenAllSettings
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
struct PodcastSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Binding var settingsRequest: SettingsWindowRequest

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                settingsRequest = .global
                openWindow(id: SettingsWindowRequest.sceneID)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
#endif

private struct SettingsPresentationHost: ViewModifier {
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#else
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @State private var sheetRequest: SettingsWindowRequest?
#endif

    let modelContainer: ModelContainer
    @Binding var settingsRequest: SettingsWindowRequest

    func body(content: Content) -> some View {
        content
            .environment(
                \.openPodcastSettings,
                OpenPodcastSettingsAction { request in
#if os(macOS)
                    settingsRequest = request
                    openWindow(id: SettingsWindowRequest.sceneID)
#else
                    if supportsMultipleWindows {
                        openWindow(id: SettingsWindowRequest.sceneID, value: request)
                    } else {
                        sheetRequest = request
                    }
#endif
                }
            )
#if !os(macOS)
            .sheet(item: $sheetRequest) { request in
                SettingsWindowContent(request: request)
                    .modelContainer(modelContainer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
#endif
    }
}

extension View {
    func hostsSettingsPresentation(
        modelContainer: ModelContainer,
        settingsRequest: Binding<SettingsWindowRequest>
    ) -> some View {
        modifier(
            SettingsPresentationHost(
                modelContainer: modelContainer,
                settingsRequest: settingsRequest
            )
        )
    }
}
