import Foundation
import CarPlay

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {
    
    var interfaceController: CPInterfaceController?
    private var nowPlaying: CarPlayNowPlaying?
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        
        // Initialize the now playing template
        nowPlaying = CarPlayNowPlaying()
        nowPlaying?.interfaceController = interfaceController
        
        // Set the now playing template as the root
        interfaceController.setRootTemplate(nowPlaying?.template ?? CPNowPlayingTemplate.shared, animated: true) { _, _ in
            print("CarPlay template loaded.")
        }
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        self.nowPlaying = nil
    }
    
    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.interfaceController?.delegate = self
    }
}
