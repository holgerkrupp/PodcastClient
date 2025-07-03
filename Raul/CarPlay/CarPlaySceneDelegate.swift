import CarPlay
import SwiftData

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        
        self.interfaceController = interfaceController
        
        self.interfaceController?.setRootTemplate(CarPlayHelloWorld().template, animated: false, completion: nil)
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }
}

    
    /*
    let container: ModelContainer? = ModelContainerManager().container
    var interfaceController: CPInterfaceController?
    var window: CPWindow?
    
    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        print("CarPlay: Connecting interface...")
        self.interfaceController = interfaceController
        self.window = window
        
        guard let container = container else {
            print("CarPlay: ModelContainer is unavailable. CarPlay integration cannot continue.")
            return
        }
        
        let playlistActor = PlaylistModelActor(modelContainer: container)
        let carPlay = CarPlayPlayNext(playlistActor: playlistActor)
        
        interfaceController.setRootTemplate(carPlay.template, animated: true) { success, error in
            if let error = error {
                print("Failed to set root template: \(error.localizedDescription)")
            } else if success {
                print("Root template set successfully.")
            }
        }
    }
    
    func templateApplicationSceneDidDisconnect(_ scene: CPTemplateApplicationScene) {
        print("CarPlay: Disconnected.")
        // Cleanup if needed
    }
}
*/
