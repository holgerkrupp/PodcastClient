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
    
    private func setupTemplate() async {
        // Fetch ordered episodes from the playlist
        self.episodes = await playlistActor.orderedEpisodeSummaries()
        let items = episodes.enumerated().map { (index, episode) in
            var cover = UIImage()
            if let url = episode.cover {
                cover = ImageWithURL(url).uiImage()
            }
            
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
                    print("CP play next: \(episode.title ?? episode.id.uuidString)")
                    await Player.shared.playEpisode(episode.id)
                    self.interfaceController.pushTemplate(CarPlayNowPlaying(interfaceController: self.interfaceController).template, animated: true, completion: { success, error in
                        print(error ?? "Error loading CarPlay Items")
                    })
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
        template.trailingNavigationBarButtons = [backButton]
    }
    
    private func returnToNowPlaying() {
        // Using self.interfaceController, implement navigation back to the now playing screen
    }
}
