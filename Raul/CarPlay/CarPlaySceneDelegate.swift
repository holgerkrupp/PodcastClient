import Foundation
import CarPlay

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {
    
    var interfaceController: CPInterfaceController?
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        
        let playlistActor = PlaylistModelActor(modelContainer: ModelContainerManager().container)

        let rootTemplate = CarPlayPlayNext(playlistActor: playlistActor).template
        interfaceController.setRootTemplate(rootTemplate, animated: true) {_,_ in 
            print("CarPlay template loaded.")
        }
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
