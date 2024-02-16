//
//  ImportExportView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 05.01.24.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportExportView: View {
    
    @State private var importing = false

    var subscriptionManager = SubscriptionManager.shared
    @State var newPodcasts: [PodcastFeed] = []

    @State private var subBaseline = 0
    
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
                            newPodcasts = await subscriptionManager.read(file: file.absoluteURL) ?? []
                        }
                    case .failure(let error):
                        print(error.localizedDescription)
                    }
                }
            }header: {
                Text("Import")
            }footer: {
                Text("Select a OPML file to import your podcasts subscriptions from different podcast apps")
            }
            
            
            if newPodcasts.filter({ newPod in
                if newPod.existing == false && newPod.added == false {
                    return true
                }else{
                    return false
                }
            }).count > 0{
                
                let notExisting = newPodcasts.filter({ newPod in
                    if newPod.existing == false && newPod.added == false {
                        return true
                    }else{
                        return false
                    }
                }).sorted(by: {$0.title ?? "" < $1.title ?? ""})
            
                    Button {
                        subBaseline = notExisting.count
                        
                        Task{
                            await subscribe()
                        }
                        
                    } label: {
                        Text("Subscribe to all \(notExisting.count) podcasts")
                        if subBaseline > 0{
                            ProgressView(value: Float(subBaseline-notExisting.count), total: Float(subBaseline))
                        
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
                        SubscribeToView(newPodcastFeed: newPodcastFeed)
                        
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
                        SubscribeToView(newPodcastFeed: newPodcastFeed)
                            
                        
                    }
                }header: {
                    Text("already subscribed")
                }
            }
            

            

        }
        .listStyle(SidebarListStyle())


    }
    
    func subscribe() async{
        _ = await newPodcasts.filter({ newPod in
            if newPod.existing == false && newPod.added == false {
                return true
            }else{
                return false
            }
        }).sorted(by: {$0.title ?? "" < $1.title ?? ""}).concurrentForEach { newFeed in
            await newFeed.subscribe()
        }
        

    }
}

#Preview {
    ImportExportView()
}



struct SubscribeToView: View{
    
    var newPodcastFeed: PodcastFeed
    
    @State private var subscribing = false
    
    var body: some View{
        HStack{
            VStack(alignment: .leading){
                Text(newPodcastFeed.title ?? "").font(.title3)
                Text(newPodcastFeed.url?.absoluteString ?? "").font(.caption)
                if newPodcastFeed.status != nil {
                    Text(newPodcastFeed.status?.statusCode?.formatted() ?? "")
                }
            }
            Spacer()
            if newPodcastFeed.existing == false{
                if newPodcastFeed.added == true{
                    Image(systemName: "checkmark.circle")
                }else{
                    if newPodcastFeed.subscribing == true{
                        ProgressView()
                    }else{
                        Button {
                            
                            Task{
                                await newPodcastFeed.subscribe()
                            }
                        } label: {

                            Text("Subscribe")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}



public extension UTType {

    static var opml: UTType {
        UTType("public.opml")!
    }
}

