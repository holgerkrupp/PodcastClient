import Foundation
import CarPlay
import SwiftData

@MainActor
final class CarPlayPlaylistSelection {
    private struct PlaylistOption {
        let id: UUID
        let title: String
    }

    private let modelContainer: ModelContainer
    private let selectedPlaylistID: UUID?
    private let onSelect: (_ id: UUID, _ title: String) -> Void

    var template: CPListTemplate

    init(
        modelContainer: ModelContainer,
        selectedPlaylistID: UUID?,
        onSelect: @escaping (_ id: UUID, _ title: String) -> Void
    ) {
        self.modelContainer = modelContainer
        self.selectedPlaylistID = selectedPlaylistID
        self.onSelect = onSelect
        self.template = CPListTemplate(title: "Playlists", sections: [])
        setupTemplate()
    }

    private func setupTemplate() {
        let playlists = loadPlaylistOptions()

        let items = playlists.map { option in
            let detailText: String?
            if option.id == selectedPlaylistID {
                detailText = "Selected"
            } else {
                detailText = nil
            }

            let item = CPListItem(
                text: option.title,
                detailText: detailText
            )
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                guard let self else {
                    completion()
                    return
                }
                self.onSelect(option.id, option.title)
                completion()
            }
            return item
        }

        if items.isEmpty {
            template.emptyViewTitleVariants = ["No playlists"]
            template.emptyViewSubtitleVariants = ["Create playlists on iPhone to select them here."]
            template.updateSections([])
            return
        }

        template.updateSections([CPListSection(items: items)])
    }

    private func loadPlaylistOptions() -> [PlaylistOption] {
        let context = ModelContext(modelContainer)
        let allPlaylists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        return Playlist.manualVisibleSorted(allPlaylists).map { playlist in
            PlaylistOption(id: playlist.id, title: playlist.displayTitle)
        }
    }
}
