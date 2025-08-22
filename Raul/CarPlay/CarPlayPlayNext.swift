import Foundation
import CarPlay
import SwiftData

@MainActor
class CarPlayPlayNext {
    let playlistActor: PlaylistModelActor
    let interfaceController: CPInterfaceController
    var template: CPListTemplate
    private var episodes: [EpisodeSummary] = []

    init(playlistActor: PlaylistModelActor, interfaceController: CPInterfaceController) {
        self.playlistActor = playlistActor
        self.interfaceController = interfaceController
        self.template = CPListTemplate(title: "Up Next", sections: [])
        Task { await self.setupTemplate() }
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
        // Load images asynchronously for all episodes
        let images: [UIImage?]? = try? await withThrowingTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, episode) in episodes.enumerated() {
                group.addTask { (index, await self.loadImage(episode: episode)) }
            }
            var results = Array<UIImage?>(repeating: nil, count: episodes.count)
            for try await (index, image) in group {
                results[index] = image
            }
            return results
        }
        let items = episodes.enumerated().map { (index, episode) in
            let cover = images?[index] ?? UIImage()
            let item = CPListItem(
                text: episode.title ?? "",
                detailText: episode.desc ?? episode.title ?? "",
                image: cover
            )
            item.userInfo = episode
            item.accessoryType = .disclosureIndicator
            item.isPlaying = (episode.id == Player.shared.currentEpisodeID)
            item.handler = { [weak self] _, _ in
                guard let self else { return }
                let episode = self.episodes[index]
                Task {
                    // print("CP play next: \(episode.title ?? episode.id.uuidString)")
                    await Player.shared.playEpisode(episode.id)
                    self.interfaceController.pushTemplate(CarPlayNowPlaying(interfaceController: self.interfaceController).template, animated: true, completion: { success, error in
                        // print(error ?? "Error loading CarPlay Items")
                    })
                    await self.refreshEpisodeList()
                }
            }
            return item
        }
        let section = CPListSection(items: items)
        template.updateSections([section])
        
        // Add a back button to return to now playing
        let backButton = CPBarButton(title: "Now Playing") { [weak self] _ in
            self?.returnToNowPlaying()
        }
        template.trailingNavigationBarButtons = []
    }
    
    private func refreshEpisodeList() async{
        self.episodes = (try? await playlistActor.orderedEpisodeSummaries()) ?? []
    }
    
    private func returnToNowPlaying() {
        // Using self.interfaceController, implement navigation back to the now playing screen
    }
}
