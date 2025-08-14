//
//  AirPlayButton.swift
//  Raul
//
//  Created by Holger Krupp on 08.08.25.
//

import SwiftUI
import AVKit

struct AirPlayButtonView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
    //    routePickerView.tintColor = .accent
        return routePickerView
    }
    
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // No update needed
    }
}
