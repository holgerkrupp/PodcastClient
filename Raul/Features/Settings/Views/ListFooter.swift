//
//  ListFooter.swift
//  Raul
//
//  Created by Holger Krupp on 16.09.25.
//

import SwiftUI
struct VersionNumberView: View {

    let
    VersionNumber = "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "0") - (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0000"))"
    
    
    var body: some View {
        
        Text(VersionNumber)
        
    }
}
