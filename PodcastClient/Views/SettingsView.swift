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
                    ActionRowView(symbol: Image(systemName: "safari.fill"), title: NSLocalizedString("Settings.MyWebsite", comment: "My Website")) {
                        UIApplication.shared.open(URL(string: "https://holgerkrupp.de")!)
                    }
                    ActionRowView(title: NSLocalizedString("Settings.MoreApps", comment: "MoreApps")) {
                        UIApplication.shared.open(URL(string: "https://apps.apple.com/developer/holger-krupp/id362806171")!)
                    }
                    ActionRowView(symbol: Image(systemName: "envelope"), title: NSLocalizedString("Contact", comment: "My Mastodon"), action:  {
                        UIApplication.shared.open(URL(string: "mailto:app-feedback@holgerkrupp.de")!)
                    })
                } header: {
                    Text("About this app")
                }
                
                
                NavigationLink {
                    
                    
                    ImportExportView()
                      
                    
                }label:{
                    Text("Import & Export")
                }
                
                NavigationLink {
                    
                    
                    PodcastSettingsView(settings: SettingsManager.shared.defaultSettings)
                    
                }label:{
                    Text("Podcast Settings")
                }
                
                Section {
                    Button {
                        Task{
                            await    SubscriptionManager().deleteAll()

                        }
                    } label: {
                        Text("Delete all Database entries")
                    }

                } header: {
                    Text("Danger Zone")
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

extension NavigationLink where Label == EmptyView, Destination == EmptyView {
    static var empty: NavigationLink {
        self.init(destination: EmptyView(), label: { EmptyView() })
    }
}
struct ActionRowView: View {
    var symbol: Image? = nil
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action, label: {
            HStack {
                if let symbol{
                    symbol
                }
                Text(title)
                Spacer()
                NavigationLink.empty
                    .frame(width: 20)
            }
        })
        .foregroundColor(.primary)
    }
}
