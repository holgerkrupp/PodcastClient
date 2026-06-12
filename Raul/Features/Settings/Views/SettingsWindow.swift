import SwiftData
import SwiftUI

struct SettingsWindowRequest: Codable, Hashable, Identifiable {
    static let sceneID = "settings"

    let podcastID: PersistentIdentifier?

    static let global = SettingsWindowRequest(podcastID: nil)

    var id: String {
        podcastID.map { String(describing: $0) } ?? "global"
    }

    static func podcast(_ podcast: Podcast) -> SettingsWindowRequest {
        SettingsWindowRequest(podcastID: podcast.persistentModelID)
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

    var body: some View {
        PodcastSettingsView(
            podcastID: request.podcastID,
            modelContainer: modelContext.container,
            embedInNavigationStack: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsPresentationHost: ViewModifier {
#if os(macOS)
    @Environment(\.openSettings) private var openSettings
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
                    openSettings()
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
