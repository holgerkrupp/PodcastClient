import Foundation
import CarPlay
import SwiftData

@MainActor
class CarPlayPlayNext {
    let playlistActor: PlaylistModelActor
    var template: CPListTemplate
    private var episodes: [EpisodeSummary] = []
    var interfaceController: CPInterfaceController?

    
    init(playlistActor: PlaylistModelActor) {
        self.playlistActor = playlistActor
        self.template = CPListTemplate(title: "Up Next", sections: [])
        Task { await self.setupTemplate() }
    }
    
    private func setupTemplate() async {
        // Fetch ordered episodes from the playlist
        self.episodes = await playlistActor.orderedEpisodeSummaries()
        let items = episodes.enumerated().map { (index, episode) in
            let item = CPListItem(
                text: episode.title ?? "",
                detailText: episode.desc ?? episode.title ?? "",
                image: nil
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
                    self.interfaceController?.pushTemplate(CarPlayNowPlaying().template, animated: true, completion: { success, error in
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
        // This will be implemented to return to the now playing screen
        // You'll need to implement this based on your navigation structure
    }
}
