//
//  ImportExportView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 05.01.24.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportExportView: View {
    @Environment(\.modelContext) private var context

    @State private var importing = false

    
    @State var newPodcasts: [PodcastFeed] = []

    @State private var subBaseline = 0
    
    @State private var fileURL:URL?
    
    var body: some View {
        List{
            Section{
                Button("Select file to import") {
                    importing = true
                }
                .fileImporter(
                    isPresented: $importing,
                    allowedContentTypes: [.opml,.xml]
                ) { result in
                    switch result {
                    case .success(let file):
                        Task{
                            newPodcasts = await SubscriptionManager(modelContainer: context.container).read(file: file.absoluteURL) ?? []
                        }
                    case .failure(let error):
                        print(error.localizedDescription)
                    }
                }
                .buttonStyle(.borderedProminent)
            }header: {
                Text("Import")
            }footer: {
                Text("Select a OPML file to import your podcasts subscriptions from different podcast apps")
            }
            
            
            Section{
                ShareLink("Export Podcasts", item: fileURL ?? URL(fileURLWithPath: ""))
                    .onAppear(){
                        Task{
                            await sharePodcasts()
                        }
                    }
                    .buttonStyle(.borderedProminent)

            }header: {
                Text("Export")
            }footer: {
                Text("Export your subscriptions as OMPL file.")
            }
            
            if newPodcasts.filter({ newPod in
                if newPod.existing == false && newPod.added == false {
                    return true
                }else{
                    return false
                }
            }).count > 0{
                
                Button("Subscribe to new podcasts"){
                    Task{
                        await SubscriptionManager(modelContainer: context.container).subscribe(all: newPodcasts.filter({ newPod in
                            if newPod.existing == false && newPod.added == false {
                                return true
                            }else{
                                return false
                            }
                        }))
                    }
                }

            
                
                Section{
                    ForEach(newPodcasts.filter({ newPod in
                        if newPod.existing == false && newPod.added == false {
                            return true
                        }else{
                            return false
                        }
                       
                    }).sorted(by: {$0.title ?? "" < $1.title ?? ""}), id: \.url) { newPodcastFeed in
                        SubscribeToPodcastView(newPodcastFeed: newPodcastFeed)
                            .modelContext(context)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 1,
                                                 trailing: 0))

                    }
                }header: {
                    Text("new Podcasts")
                }
            }
            
            if newPodcasts.filter({ newPod in
                return newPod.existing == true
            }).count > 0{
                Section{
                    ForEach(newPodcasts.filter({ newPod in
                        return newPod.existing == true
                    }), id: \.url) { newPodcastFeed in
                       SubscribeToPodcastView(newPodcastFeed: newPodcastFeed)
                            .modelContext(context)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 1,
                                                 trailing: 0))

                        
                    }
                }header: {
                    Text("already subscribed")
                }
            }
            

            

        }
        .listStyle(.plain)
        .navigationTitle("Import")


    }
    

    //@MainActor
    func sharePodcasts() async{
        print("share")
        
            fileURL = try? await saveToTemporaryFile(content: SubscriptionManager(modelContainer: context.container).generateOPML(), fileName: "Podcasts.opml")
        
        
    }
    
    func saveToTemporaryFile(content: String, fileName: String) throws -> URL {
        print("save")
        let tempDirectoryURL = FileManager.default.temporaryDirectory
        let fileURL = tempDirectoryURL.appendingPathComponent(fileName)
        do{
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }catch{
            print(error)
        }
        print(fileURL)
        return fileURL
    }
    
    
}

#Preview {
    ImportExportView()
}







public extension UTType {

    static var opml: UTType {
        UTType("public.opml")!
    }
}

