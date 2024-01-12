//
//  SettingsView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 17.12.23.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) var modelContext

    var body: some View {
        NavigationStack {
            List{
                Section {
                    Text("developed by Holger Krupp")
                } header: {
                    Text("About this app")
                }
                
                NavigationLink {
                    
                    
                    ImportExportView()
                       
                    
                }label:{
                    Text("Import & Export")
                }
                
                
                
                VersionNumberView()
            }
        }
    }
}

#Preview {
    SettingsView()
}


struct VersionNumberView: View {
    //First get the nsObject by defining as an optional anyObject
    
    let
    VersionNumber = "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "0") - (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0000"))"
    
    
    var body: some View {
        
        Text(VersionNumber).font(.footnote)
        
    }
}
