import Foundation
import CarPlay
import SwiftData

private final class CarPlayPlayNextNotificationObserver: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor
class CarPlayPlayNext {
    var playlistActor: PlaylistModelActor
    let interfaceController: CPInterfaceController
    var template: CPListTemplate
    private var episodes: [EpisodeSummary] = []
    private var notificationObserver: CarPlayPlayNextNotificationObserver?
    private var artworkSettingsObserver: CarPlayPlayNextNotificationObserver?
    private var refreshTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var inbox: CarPlayInbox?
    private var textChapterList: CarPlayChapterMarkList?
    private var generation = 0
    private var selectedPlaylistID: UUID?
    private var selectedPlaylistTitle: String = Playlist.defaultQueueDisplayName

    init(playlistActor: PlaylistModelActor, interfaceController: CPInterfaceController) {
        self.playlistActor = playlistActor
        self.interfaceController = interfaceController
        self.selectedPlaylistID = Playlist.resolvePlaylistID(
            from: UserDefaults.standard.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        )
        self.template = CPListTemplate(title: Playlist.defaultQueueDisplayName, sections: [])
        observeChanges()
        scheduleRefresh()
    }

    deinit {
        refreshTask?.cancel()
        artworkTask?.cancel()
    }

    func invalidate() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        inbox?.invalidate()
        inbox = nil
        textChapterList?.invalidate()
        textChapterList = nil
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
        notificationObserver = CarPlayPlayNextNotificationObserver(token: token)
        let artworkToken = NotificationCenter.default.addObserver(
            forName: CarPlayArtworkSettings.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        artworkSettingsObserver = CarPlayPlayNextNotificationObserver(token: artworkToken)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.setupTemplate()
        }
    }

    private func setupTemplate() async {
        artworkTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        await refreshEpisodeList()
        guard Task.isCancelled == false, requestGeneration == generation else { return }

        let current = Player.shared.currentEpisode
        let currentEpisodeURL = Player.shared.currentEpisodeURL
        let queueEpisodes = episodes.filter { episode in
            guard let currentEpisodeURL else { return true }
            return episode.url != currentEpisodeURL
        }
        let totalLimit = max(1, CPListTemplate.maximumItemCount)
        let currentCount = current == nil ? 0 : 1
        let playbackActionsCount = current != nil && CarPlayArtworkSettings.showArtwork == false ? 1 : 0
        let needsMoreRow = currentCount + playbackActionsCount + queueEpisodes.count > totalLimit
        let availableQueueCount = max(0, totalLimit - currentCount - playbackActionsCount - (needsMoreRow ? 1 : 0))
        let displayedEpisodes = Array(queueEpisodes.prefix(availableQueueCount))
        var sections: [CPListSection] = []
        var imageTargets: [(item: CPListItem, url: URL)] = []

        if let current {
            let currentItem = CPListItem(
                text: carPlayText(current.title),
                detailText: carPlayText(current.desc ?? current.title),
                image: nil
            )
            currentItem.userInfo = current
            currentItem.isPlaying = true
            currentItem.accessoryType = .disclosureIndicator
            currentItem.handler = { [weak self] _, completion in
                completion()
                guard let self else { return }
                let controller = self.interfaceController
                Task { await Player.shared.playEpisode(current.url) }
                controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            }
            if let url = current.summary.cover ?? current.summary.podcastCover {
                imageTargets.append((currentItem, url))
            }
            var currentItems = [currentItem]
            if CarPlayArtworkSettings.showArtwork == false {
                let actionsItem = CPListItem(text: "Playback actions", detailText: "Chapters and bookmark", image: nil)
                actionsItem.accessoryType = .disclosureIndicator
                actionsItem.handler = { [weak self] _, completion in
                    completion()
                    self?.showTextPlaybackActions()
                }
                currentItems.append(actionsItem)
            }
            sections.append(CPListSection(items: currentItems))
        }

        let queueItems = displayedEpisodes.map { episode in
            let item = CPListItem(
                text: carPlayText(episode.title),
                detailText: carPlayText(episode.desc ?? episode.title),
                image: nil
            )
            item.userInfo = episode
            item.accessoryType = .disclosureIndicator
            item.isPlaying = episode.url == currentEpisodeURL
            item.handler = { [weak self] _, completion in
                completion()
                guard let self else { return }
                let controller = self.interfaceController
                controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if episode.url == Player.shared.currentEpisodeURL {
                        Player.shared.play()
                    } else {
                        await Player.shared.playEpisode(episode.url)
                    }
                    self.scheduleRefresh()
                }
            }
            if let url = episode.cover ?? episode.podcastCover {
                imageTargets.append((item, url))
            }
            return item
        }
        if queueItems.isEmpty == false {
            sections.append(CPListSection(items: queueItems))
        }

        if needsMoreRow, totalLimit > 0 {
            let moreItem = CPListItem(
                text: "Open Up Next on iPhone to see more",
                detailText: nil,
                image: nil
            )
            if sections.isEmpty {
                sections.append(CPListSection(items: [moreItem]))
            } else if let lastSection = sections.last {
                sections[sections.count - 1] = CPListSection(
                    items: lastSection.items + [moreItem]
                )
            }
        }

        template.updateSections(sections)
        configureNavigationButtons()

        let displayScale = interfaceController.carTraitCollection.displayScale
        let maxPixelSize = CarPlayArtworkProvider.pixelBudget(displayScale: displayScale)
        let targets = imageTargets
        let activeTemplate = template
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

    private func showTextPlaybackActions() {
        var actions: [CPListItem] = []
        if Player.shared.currentEpisode?.preferredChapters.isEmpty == false {
            let chaptersItem = CPListItem(text: "Chapters", detailText: nil, image: nil)
            chaptersItem.accessoryType = .disclosureIndicator
            chaptersItem.handler = { [weak self] _, completion in
                completion()
                guard let self else { return }
                let chapterList = CarPlayChapterMarkList(interfaceController: self.interfaceController)
                self.textChapterList?.invalidate()
                self.textChapterList = chapterList
                self.interfaceController.pushTemplate(chapterList.template, animated: true, completion: nil)
            }
            actions.append(chaptersItem)
        }
        let bookmarkItem = CPListItem(text: "Bookmark current position", detailText: nil, image: nil)
        bookmarkItem.handler = { [weak self] _, completion in
            completion()
            Player.shared.createBookmark()
            self?.interfaceController.popTemplate(animated: true, completion: nil)
        }
        actions.append(bookmarkItem)
        let actionTemplate = CPListTemplate(title: "Playback actions", sections: [CPListSection(items: actions)])
        interfaceController.pushTemplate(actionTemplate, animated: true, completion: nil)
    }

    private func configureNavigationButtons() {
        let inboxButton = CPBarButton(title: "Inbox") { [weak self] _ in
            guard let self else { return }
            let inbox = CarPlayInbox(
                playlistActor: self.playlistActor,
                interfaceController: self.interfaceController
            )
            self.inbox?.invalidate()
            self.inbox = inbox
            self.interfaceController.pushTemplate(inbox.template, animated: true, completion: nil)
        }
        let playlistsButton = CPBarButton(title: "Playlists") { [weak self] _ in
            self?.presentPlaylistSelection()
        }
        template.leadingNavigationBarButtons = [playlistsButton]
        template.trailingNavigationBarButtons = [inboxButton]
    }

    private func refreshEpisodeList() async {
        episodes = (try? await playlistActor.orderedEpisodeSummaries(
            limit: max(1, CPListTemplate.maximumItemCount) + 1
        )) ?? []
    }

    private func carPlayText(_ text: String?) -> String {
        guard let text else { return "" }
        return (text.plainTextFromHTML() ?? text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func presentPlaylistSelection() {
        let selector = CarPlayPlaylistSelection(
            modelContainer: playlistActor.modelContainer,
            selectedPlaylistID: selectedPlaylistID
        ) { [weak self] selectedID, selectedTitle in
            guard let self else { return }
            self.applyPlaylistSelection(id: selectedID, title: selectedTitle)
        }
        interfaceController.pushTemplate(selector.template, animated: true, completion: nil)
    }

    private func applyPlaylistSelection(id: UUID, title: String) {
        guard let newPlaylistActor = try? PlaylistModelActor(
            modelContainer: playlistActor.modelContainer,
            playlistID: id
        ) else { return }

        playlistActor = newPlaylistActor
        selectedPlaylistID = id
        selectedPlaylistTitle = title
        UserDefaults.standard.set(id.uuidString, forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        artworkTask?.cancel()
        template = CPListTemplate(title: selectedPlaylistTitle, sections: [])
        interfaceController.setRootTemplate(template, animated: true, completion: nil)
        scheduleRefresh()
    }
}
