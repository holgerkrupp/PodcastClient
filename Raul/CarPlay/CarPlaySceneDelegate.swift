import CarPlay
import SwiftData

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    let container = ModelContainerManager().container
    var interfaceController: CPInterfaceController?
    var window: CPWindow?
    
    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController
        self.window = window
        
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
        // Cleanup if needed
    }
}
