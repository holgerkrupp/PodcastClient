//
//  iPadMainView.swift
//  Raul
//
//  Created by Holger Krupp on 22.09.25.
//

import SwiftUI

struct iPadMainView: View {
    
    @State private var search:String = ""

    
    var body: some View {
        HStack {
            NavigationSplitView {
                LibraryView()
                    .toolbar {
                        ToolbarItem{
                            NavigationLink{
                                AddPodcastView(search: $search)
                            } label: {
                                Label("Add Podcast", systemImage: "plus")
                            }
                        }
                    }

                
            }detail: {
                LibraryView()
            }


            
            VStack{
                PlayerView(fullSize: false)
                PlaylistView()
            }
        }


    }
}

#Preview {
    iPadMainView()
}
