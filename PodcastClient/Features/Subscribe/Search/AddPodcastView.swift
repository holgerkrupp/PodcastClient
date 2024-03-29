//
//  AddPodcastView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 08.12.23.
//

import SwiftUI

struct AddPodcastView: View {
    @Environment(\.modelContext) var modelContext

    @State var newFeed:String = ""
    @State private var updateing = false
    @State private var searchResults:[PodcastFeed]?
    @State private var error:Error?
    var parserDelegate = PodcastParser()
    var subscriptionManager = SubscriptionManager.shared
    
    var feed:URL?{
        URL(string: newFeed.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    var body: some View {
        NavigationStack{
            List{
                Section {
                    NavigationLink {
                        
                        ImportExportView()
                        
                    }label:{
                        Text("Import & Export")
                    }
                }
                
                Section {
                    HStack{
                        TextField(text: $newFeed) {
                            Text("Search or enter URL")
                        }.disabled(updateing)
                            .onSubmit {
                                error = nil
                                search()
                            }
                        if let subError = error as? SubscriptionManager.SubscribeError{
                            Text(subError.description).font(.caption)
                        }
                        
                        Button {
                            search()
                            
                        } label: {
                            if updateing{
                                ProgressView()
                            }else{
                                if (newFeed.isValidURL) {
                                    Text("Subscribe")
                                }else{
                                    Text("Search")
                                }
                            }
                            
                        }
                        .disabled(newFeed.isEmpty || updateing)
                        .buttonStyle(.bordered)
                    }
                }
                
                
                
                if let searchResults{
                    Section{
                        SearchResultView(searchResults: searchResults).id(UUID())
                    }
                }else{
                    SuggestionsView()
                }
                
                
            }
            
            
        }
    }
    
    func search(){
        updateing = true
        if let feed, newFeed.isValidURL {
            Task{
                
                do {
                    let result = try await subscriptionManager.subscribe(to: feed)
                    newFeed = ""// handle success case
                    updateing = false
                    error = nil
                } catch {
                    let errorString = "Error: \(error)"
                    self.error = error
                    updateing = false
                    print(errorString)
                }
                
            }
        }else{
            Task{
                searchResults = nil
                searchResults = await FyydSearchManager().search(for: newFeed)
                updateing = false
            }
            
        }
    }
    
}

#Preview {
    AddPodcastView()
}
