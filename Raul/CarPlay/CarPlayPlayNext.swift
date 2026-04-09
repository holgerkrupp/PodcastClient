import Foundation
import CarPlay
import SwiftData

@MainActor
class CarPlayPlayNext {
    let playlistActor: PlaylistModelActor
    let interfaceController: CPInterfaceController
    var template: CPListTemplate
    private var episodes: [EpisodeSummary] = []
    private var notificationToken: NSObjectProtocol?

    init(playlistActor: PlaylistModelActor, interfaceController: CPInterfaceController) {
        self.playlistActor = playlistActor
        self.interfaceController = interfaceController
        self.template = CPListTemplate(title: "Up Next", sections: [])
        observeChanges()
        Task { await self.setupTemplate() }
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
    
    private func loadImage(episode: EpisodeSummary) async -> UIImage?{
        
        guard let imageURL =  episode.cover ?? episode.podcastCover else {
            // print("imageURL is nil")
            return nil }
        
        return await ImageLoaderAndCache.loadUIImage(from: imageURL)
    }
    
    
    private func setupTemplate() async {
        // Fetch ordered episodes from the playlist
        await self.refreshEpisodeList()
        let currentEpisodeURL = Player.shared.currentEpisodeURL
        let queueEpisodes = episodes.filter { episode in
            guard let currentEpisodeURL else { return true }
            return episode.url != currentEpisodeURL
        }

        // Prepare an array of sections we will show in the template
        var sections: [CPListSection] = []

        // Section 0: Currently Playing (if any)
        if let current = Player.shared.currentEpisode {
            // Load current episode image
            let currentImage = await self.loadImage(episode: current.summary) ?? UIImage()
            let currentEpisodeURL = current.url
            let interfaceController = self.interfaceController
            let nowPlayingItem = CPListItem(
                text: current.title,
                detailText: current.desc ?? current.title,
                image: currentImage
            )
            nowPlayingItem.userInfo = current
            nowPlayingItem.isPlaying = true
            nowPlayingItem.accessoryType = .disclosureIndicator
            nowPlayingItem.handler = { _, _ in
                Task {
                    await Player.shared.playEpisode(currentEpisodeURL)
                }
                interfaceController.pushTemplate(
                    CarPlayNowPlaying(interfaceController: interfaceController).template,
                    animated: true,
                    completion: { _, _ in }
                )
            }
            let nowPlayingSection = CPListSection(items: [nowPlayingItem])
            sections.append(nowPlayingSection)
        }

        // Load images asynchronously for all episodes in Up Next
        let images: [UIImage?]? = try? await withThrowingTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, episode) in queueEpisodes.enumerated() {
                group.addTask { (index, await self.loadImage(episode: episode)) }
            }
            var results = Array<UIImage?>(repeating: nil, count: queueEpisodes.count)
            for try await (index, image) in group {
                results[index] = image
            }
            return results
        }

        // Build Up Next items
        let items = queueEpisodes.enumerated().map { index, episode in
            let cover = images?[index] ?? UIImage()
            let item = CPListItem(
                text: episode.title ?? "",
                detailText: episode.desc ?? episode.title ?? "",
                image: cover
            )
            item.userInfo = episode
            item.accessoryType = .disclosureIndicator
            item.isPlaying = (episode.url == Player.shared.currentEpisodeURL)
            item.handler = { [weak self] _, _ in
                guard let self else { return }
                Task {
                    if episode.url == Player.shared.currentEpisodeURL {
                        Player.shared.play()
                    } else {
                        await Player.shared.playEpisode(episode.url)
                    }
                    self.interfaceController.pushTemplate(
                        CarPlayNowPlaying(interfaceController: self.interfaceController).template,
                        animated: true,
                        completion: { _, _ in }
                    )
                    await self.setupTemplate()
                }
            }
            return item
        }

        // Add Up Next section
        if items.isEmpty == false {
            let upNextSection = CPListSection(items: items)
            sections.append(upNextSection)
        }

        // Update the template with all sections
        template.updateSections(sections)

        let inboxButton = CPBarButton(title: "Inbox") { [weak self] _ in
            guard let self else { return }
            let inbox = CarPlayInbox(playlistActor: self.playlistActor, interfaceController: self.interfaceController)
            self.interfaceController.pushTemplate(inbox.template, animated: true, completion: nil)
        }

        template.leadingNavigationBarButtons = [inboxButton]
        template.trailingNavigationBarButtons = []
    }
    
    private func refreshEpisodeList() async{
        self.episodes = (try? await playlistActor.orderedEpisodeSummaries()) ?? []
    }
    
    private func returnToNowPlaying() {
        let nowPlaying = CarPlayNowPlaying(interfaceController: self.interfaceController)
        
        let nowPlayingTemplate = nowPlaying.template
        
        interfaceController.setRootTemplate(nowPlayingTemplate, animated: true, completion: nil)
    }

}
