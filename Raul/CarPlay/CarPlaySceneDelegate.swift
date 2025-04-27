import Foundation
import CarPlay

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {
    
    var interfaceController: CPInterfaceController?
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        
        self.interfaceController = interfaceController
        let playListModelActor = PlaylistModelActor(modelContainer: ModelContainerManager().container, playlistID: PlaylistManager.shared.playnext.id)
        self.interfaceController?.setRootTemplate(CarPlayPlayNext(playlistActor: playListModelActor).template, animated: false, completion: nil)
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }
    
    
    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.interfaceController?.delegate = self
     /*
        self.setupNowPlayingTemplate()
        self.setRootTemplate()
        self.initializeDataIfNeeded()
    */
      }
    
}
