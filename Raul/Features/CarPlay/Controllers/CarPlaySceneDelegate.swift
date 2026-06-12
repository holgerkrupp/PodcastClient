#if os(iOS)
import CarPlay
import SwiftData

@MainActor
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    var playNext: CarPlayPlayNext?
    var nowPlaying: CarPlayNowPlaying?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        let loadingTemplate = CPListTemplate(title: "Up Next", sections: [])
        loadingTemplate.emptyViewTitleVariants = ["Loading"]
        interfaceController.setRootTemplate(loadingTemplate, animated: false, completion: nil)

        Task { @MainActor [weak self, weak interfaceController] in
            guard let self, let interfaceController else { return }

            let containerManager = ModelContainerManager.shared
            await containerManager.prepareContainer()

            guard self.interfaceController === interfaceController else { return }
            guard let container = containerManager.preparedContainer,
                  let playlistActor = try? PlaylistModelActor(modelContainer: container) else {
                loadingTemplate.emptyViewTitleVariants = ["Unable to load Up Next"]
                loadingTemplate.emptyViewSubtitleVariants = [containerManager.initializationError ?? "Open Up Next on iPhone and try again."]
                loadingTemplate.updateSections([])
                return
            }

            let playNext = CarPlayPlayNext(playlistActor: playlistActor, interfaceController: interfaceController)
            self.playNext = playNext

            let nowPlaying = CarPlayNowPlaying(interfaceController: interfaceController)
            self.nowPlaying = nowPlaying

            interfaceController.setRootTemplate(playNext.template, animated: false, completion: nil)
        }
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        guard self.interfaceController === interfaceController else { return }
        self.interfaceController = nil
        playNext = nil
        nowPlaying = nil
    }
}
#endif
