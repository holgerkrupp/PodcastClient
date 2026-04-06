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

        var images: [UIImage?] = []
        images.reserveCapacity(episodes.count)
        for episode in episodes {
            images.append(await loadImage(for: episode.summary))
        }

        let items = episodes.enumerated().map { index, episode in
            let item = CPListItem(
                text: episode.title,
                detailText: episode.subtitle ?? episode.desc ?? episode.podcast?.title,
                image: images[index] ?? UIImage()
            )
            item.userInfo = episode.summary
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                guard let self else {
                    completion()
                    return
                }
                self.presentActions(for: episode)
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
        let playNext = CPAlertAction(title: "Play Next", style: .default) { [weak self] _ in
            guard let self else { return }
            Task {
                if let url = episode.url {
                    try? await self.playlistActor.insert(episodeURL: url, after: Player.shared.currentEpisodeURL)
                    await self.setupTemplate()
                }
                self.interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        }

        let playLast = CPAlertAction(title: "Play Last", style: .default) { [weak self] _ in
            guard let self else { return }
            Task {
                if let url = episode.url {
                    try? await self.playlistActor.add(episodeURL: url, to: .end)
                    await self.setupTemplate()
                }
                self.interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        }

        let archive = CPAlertAction(title: "Archive", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.episodeActor.archiveEpisode(episode.url)
                await self.setupTemplate()
                self.interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        }

        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }

        let sheet = CPActionSheetTemplate(
            title: episode.title,
            message: episode.podcast?.title,
            actions: [playNext, playLast, archive, cancel]
        )
        interfaceController.presentTemplate(sheet, animated: true, completion: nil)
    }

    private func loadImage(for episode: EpisodeSummary) async -> UIImage? {
        guard let imageURL = episode.cover ?? episode.podcastCover else { return nil }
        return await ImageLoaderAndCache.loadUIImage(from: imageURL)
    }
}
