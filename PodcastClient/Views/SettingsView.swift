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
                 
                    ActionRowView(symbol: Image(systemName: "safari.fill"), title: "Developed by Holger Krupp") {
                        UIApplication.shared.open(URL(string: "https://holgerkrupp.de")!)
                    }
                    ActionRowView(symbol: Image(systemName: "apps.iphone"), title: "My other Apps", action:  {
                        UIApplication.shared.open(URL(string: "https://apps.apple.com/developer/holger-krupp/id362806171")!)
                    })
                    ActionRowView(symbol: Image(systemName: "text.badge.xmark"), title: "Get the source code", action:  {
                        UIApplication.shared.open(URL(string: "https://github.com/holgerkrupp/PodcastClient/")!)
                    })
                    ActionRowView(symbol: Image(systemName: "ladybug"), title: "Report bugs on GitHub", action:  {
                        UIApplication.shared.open(URL(string: "https://github.com/holgerkrupp/PodcastClient/issues")!)
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
    
    var compileDate:Date
    {
        let bundleName = Bundle.main.infoDictionary!["CFBundleName"] as? String ?? "Info.plist"
        if let infoPath = Bundle.main.path(forResource: bundleName, ofType: nil),
           let infoAttr = try? FileManager.default.attributesOfItem(atPath: infoPath),
           let infoDate = infoAttr[FileAttributeKey.creationDate] as? Date
        { return infoDate }
        return Date()
    }
    
    let
    VersionNumber = "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "0") - (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0000"))"
    
    
    var body: some View {
        
        Text(VersionNumber).font(.footnote)
        Text(compileDate.formatted()).font(.footnote)
        
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
