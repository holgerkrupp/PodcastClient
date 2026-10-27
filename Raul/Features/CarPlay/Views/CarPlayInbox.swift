import Foundation
import CarPlay
import SwiftData

private final class CarPlayInboxNotificationObserver: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor
class CarPlayInbox {
    let interfaceController: CPInterfaceController
    let playlistActor: PlaylistModelActor
    private let episodeActor: EpisodeActor
    private let modelContext: ModelContext
    var template: CPListTemplate
    private var notificationObserver: CarPlayInboxNotificationObserver?
    private var artworkSettingsObserver: CarPlayInboxNotificationObserver?
    private var refreshTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var generation = 0

    init(playlistActor: PlaylistModelActor, interfaceController: CPInterfaceController) {
        self.playlistActor = playlistActor
        self.interfaceController = interfaceController
        let container = playlistActor.modelContainer
        self.episodeActor = EpisodeActor(modelContainer: container)
        self.modelContext = ModelContext(container)
        self.template = CPListTemplate(title: "Inbox", sections: [])
        self.template.emptyViewTitleVariants = ["Your Inbox is empty"]
        self.template.emptyViewSubtitleVariants = ["New episodes will appear here."]
        observeChanges()
        scheduleRefresh()
    }

    deinit { refreshTask?.cancel(); artworkTask?.cancel() }

    func invalidate() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        notificationObserver = nil
        artworkSettingsObserver = nil
    }

    func refreshForArtworkPreferenceChange() { scheduleRefresh() }

    private func observeChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: .inboxDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        notificationObserver = CarPlayInboxNotificationObserver(token: token)
        let artworkToken = NotificationCenter.default.addObserver(
            forName: CarPlayArtworkSettings.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        artworkSettingsObserver = CarPlayInboxNotificationObserver(token: artworkToken)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.setupTemplate() }
    }

    private func setupTemplate() async {
        artworkTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        let itemLimit = max(1, CPListTemplate.maximumItemCount)
        let fetchedEpisodes = loadInboxEpisodes(limit: itemLimit + 1)
        let needsMoreRow = fetchedEpisodes.count > itemLimit
        let visibleLimit = max(0, itemLimit - (needsMoreRow ? 1 : 0))
        let episodes = Array(fetchedEpisodes.prefix(visibleLimit))
        guard Task.isCancelled == false else { return }

        var imageTargets: [(item: CPListItem, url: URL)] = []
        let items = episodes.map { episode in
            let item = CPListItem(
                text: carPlayText(episode.title),
                detailText: carPlayText(episode.subtitle ?? episode.desc ?? episode.displayPodcastTitle),
                image: nil
            )
            item.userInfo = episode.summary
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                completion()
                self?.presentActions(episode)
            }
            if let url = episode.summary.cover ?? episode.summary.podcastCover {
                imageTargets.append((item, url))
            }
            return item
        }
        var visibleItems = items
        if needsMoreRow {
            visibleItems.append(CPListItem(
                text: "Open Inbox on iPhone to see more",
                detailText: nil,
                image: nil
            ))
        }
        template.updateSections(visibleItems.isEmpty ? [] : [CPListSection(items: visibleItems)])

        let targets = imageTargets
        let activeTemplate = template
        let maxPixelSize = CarPlayArtworkProvider.pixelBudget(
            displayScale: interfaceController.carTraitCollection.displayScale
        )
        artworkTask = Task { [weak self] in
            await CarPlayArtworkProvider.loadBounded(
                requests: targets.enumerated().map { (index: $0.offset, url: $0.element.url) },
                maxPixelSize: maxPixelSize
            ) { index, image in
                guard let self,
                      self.generation == requestGeneration,
                      self.template === activeTemplate,
                      Task.isCancelled == false else { return }
                targets[index].item.setImage(image)
            }
        }
    }

    private func loadInboxEpisodes(limit: Int) -> [Episode] {
        let predicate = #Predicate<Episode> { $0.metaData?.isInbox == true }
        let sortDescriptor = SortDescriptor<Episode>(\.publishDate, order: .reverse)
        var descriptor = FetchDescriptor<Episode>(predicate: predicate, sortBy: [sortDescriptor])
        descriptor.fetchLimit = limit
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func presentActions(_ episode: Episode) {
        let playlistActor = self.playlistActor
        let episodeActor = self.episodeActor
        let interfaceController = self.interfaceController
        let refreshTemplate = self.scheduleRefresh

        let playNext = CPAlertAction(title: "Play Next", style: .default) { _ in
            Task {
                if let url = episode.url {
                    try? await playlistActor.insert(episodeURL: url, after: Player.shared.currentEpisodeURL)
                    refreshTemplate()
                }
                interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        }
        let playLast = CPAlertAction(title: "Play Last", style: .default) { _ in
            Task {
                if let url = episode.url {
                    try? await playlistActor.add(episodeURL: url, to: .end)
                    refreshTemplate()
                }
                interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        }
        let removeFromInbox = CPAlertAction(title: "Remove from Inbox", style: .destructive) { _ in
            Task {
                await episodeActor.removeFromInbox(episode.url)
                refreshTemplate()
                interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        }
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { _ in
            interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let sheet = CPActionSheetTemplate(
            title: episode.title,
            message: episode.displayPodcastTitle,
            actions: [playNext, playLast, removeFromInbox, cancel]
        )
        interfaceController.presentTemplate(sheet, animated: true, completion: nil)
    }

    private func carPlayText(_ text: String?) -> String {
        guard let text else { return "" }
        return (text.plainTextFromHTML() ?? text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
