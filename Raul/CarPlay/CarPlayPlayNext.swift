import Foundation
import CarPlay
import SwiftData

@MainActor
class CarPlayPlayNext {
    private let playlistActor: PlaylistModelActor
    private let player = Player.shared
    private(set) var interfaceController: CPInterfaceController?
    
    init(playlistActor: PlaylistModelActor) {
        self.playlistActor = playlistActor
    }
    
    var template: CPListTemplate {
        return CPListTemplate(title: "Up Next", sections: [self.section])
    }
    
    private func fetchItems() async -> [CPListItem] {
        var listItems: [CPListItem] = []
        
       // let episodes = await playlistActor.orderedEpisodes()
        let episodes = [] as [Episode]
        
        for episode in episodes {
            var cover = UIImage(systemName: "globe")
            /*
            if let data = episode.cover {
                cover = ImageWithData(data).uiImage()
            } else if let data = episode.podcast?.cover {
                cover = ImageWithData(data).uiImage()
            }
            */
            let listItem = CPListItem(
                text: episode.title,
                detailText: episode.podcast?.title,
                image: cover
            )
            listItem.userInfo = episode
            listItem.accessoryType = .disclosureIndicator
            listItem.isPlaying = (episode == player.currentEpisode)
            
            listItem.handler = { [weak self] item, completion in
                guard let self = self else { return }
                if let episode = item.userInfo as? Episode {
                    self.player.playEpisode(episode, playDirectly: true)
                    
                    self.interfaceController?.pushTemplate(CarPlayNowPlaying().template, animated: true, completion: { success, error in
                        if let error = error {
                            print("❌ Error pushing NowPlaying template: \(error)")
                        }
                        completion()
                    })
                } else {
                    completion()
                }
            }
            
            listItems.append(listItem)
        }
        
        return listItems
    }
    
    private var section: CPListSection {
        return CPListSection(items: [])
    }
    
    func reloadInterface() {
        Task { @MainActor in
            let items = await fetchItems()
            let section = CPListSection(items: items)
            let template = CPListTemplate(title: "Up Next", sections: [section])
          //  try? await interfaceController?.setRootTemplate(template, animated: true)
        }
    }
}
