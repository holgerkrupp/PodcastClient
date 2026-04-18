import Foundation
import CarPlay
import SwiftData

@MainActor
class CarPlayInbox {
    let interfaceController: CPInterfaceController
    let playlistActor: PlaylistModelActor
    private let episodeActor = EpisodeActor(modelContainer: ModelContainerManager.shared.container)
    private let modelContext = ModelContext(ModelContainerManager.shared.container)
    var template: CPListTemplate
    private var notificationToken: NSObjectProtocol?

    init(playlistActor: PlaylistModelActor, interfaceController: CPInterfaceController) {
        self.playlistActor = playlistActor
        self.interfaceController = interfaceController
        self.template = CPListTemplate(title: "Inbox", sections: [])
        self.template.emptyViewTitleVariants = ["Your Inbox is empty"]
        self.template.emptyViewSubtitleVariants = ["New episodes will appear here."]
        observeChanges()
        Task {
            await self.setupTemplate()
        }
    }

    private func observeChanges() {
        notificationToken = NotificationCenter.default.addObserver(
            forName: .inboxDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.setupTemplate() }
        }
    }

    private func setupTemplate() async {
        let episodes = loadInboxEpisodes()
        let presentActions = self.presentActions

        var images: [UIImage?] = []
        images.reserveCapacity(episodes.count)
        for episode in episodes {
            images.append(await loadImage(for: episode.summary))
        }

        let items = episodes.enumerated().map { index, episode in
            let item = CPListItem(
                text: episode.title,
                detailText: episode.subtitle ?? episode.desc ?? episode.displayPodcastTitle,
                image: images[index] ?? UIImage()
            )
            item.userInfo = episode.summary
            item.accessoryType = .disclosureIndicator
            item.handler = { _, completion in
                presentActions(episode)
                completion()
            }
            return item
        }

        template.updateSections([CPListSection(items: items)])
    }

    private func loadInboxEpisodes() -> [Episode] {
        let predicate = #Predicate<Episode> { $0.metaData?.isInbox == true }
        let sortDescriptor = SortDescriptor<Episode>(\.publishDate, order: .reverse)
        let descriptor = FetchDescriptor<Episode>(predicate: predicate, sortBy: [sortDescriptor])
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func presentActions(for episode: Episode) {
        let playlistActor = self.playlistActor
        let episodeActor = self.episodeActor
        let interfaceController = self.interfaceController
        let refreshTemplate = self.setupTemplate

        let playNext = CPAlertAction(title: "Play Next", style: .default) { _ in
            Task {
                if let url = episode.url {
                    try? await playlistActor.insert(episodeURL: url, after: Player.shared.currentEpisodeURL)
                    await refreshTemplate()
                }
                interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        }

        let playLast = CPAlertAction(title: "Play Last", style: .default) { _ in
            Task {
                if let url = episode.url {
                    try? await playlistActor.add(episodeURL: url, to: .end)
                    await refreshTemplate()
                }
                interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        }

        let archive = CPAlertAction(title: "Archive", style: .destructive) { _ in
            Task {
                await episodeActor.archiveEpisode(episode.url)
                await refreshTemplate()
                interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        }

        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { _ in
            interfaceController.dismissTemplate(animated: true, completion: nil)
        }

        let sheet = CPActionSheetTemplate(
            title: episode.title,
            message: episode.displayPodcastTitle,
            actions: [playNext, playLast, archive, cancel]
        )
        interfaceController.presentTemplate(sheet, animated: true, completion: nil)
    }

    private func loadImage(for episode: EpisodeSummary) async -> UIImage? {
        guard let imageURL = episode.cover ?? episode.podcastCover else { return nil }
        return await ImageLoaderAndCache.loadUIImage(from: imageURL)
    }
}
