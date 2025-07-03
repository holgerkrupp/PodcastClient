//
//  CarPlaySceneDelegate.swift
//  CPHelloWorld
//
//  Created by Paul Wilkinson on 16/5/2023.
//

import Foundation
import CarPlay

class CarPlaySceneDelegate2: UIResponder, CPTemplateApplicationSceneDelegate {
    
    var interfaceController: CPInterfaceController?
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        
        self.interfaceController = interfaceController
        
        self.interfaceController?.setRootTemplate(CarPlayHelloWorld().template, animated: false, completion: nil)
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }
}
