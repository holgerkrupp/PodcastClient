//
//  RaulApp.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import SwiftData

@main
struct RaulApp: App {
    @StateObject private var modelContainerManager = ModelContainerManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainerManager.container)
                .accentColor(.accent)
        }
    }
}
