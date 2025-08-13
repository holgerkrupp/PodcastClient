import CarPlay
import SwiftData

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    var playNext: CarPlayPlayNext?
    var nowPlaying: CarPlayNowPlaying?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

       // let playlistActor = PlaylistModelActor(modelContainer: ModelContainerManager().container!)
        if let playlistActor = try? PlaylistModelActor(){
            
            let playNext = CarPlayPlayNext(playlistActor: playlistActor, interfaceController: interfaceController)
            self.playNext = playNext
            
            let nowPlaying = CarPlayNowPlaying(interfaceController: interfaceController)
            self.nowPlaying = nowPlaying
            
            self.interfaceController?.setRootTemplate(playNext.template, animated: false, completion: nil)
        }
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }
}
