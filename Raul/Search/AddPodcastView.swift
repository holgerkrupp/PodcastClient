//
//  AddPodcastView.swift
//  Raul
//
//  Created by Holger Krupp on 03.04.25.
//

import SwiftUI

struct AddPodcastView: View {
    enum Selection {
        case search, hot
    }
    @State private var listSelection:Selection = .search
    var body: some View {
    
            Picker(selection: $listSelection) {
                Text("Search").tag(Selection.search)
                Text("Hot").tag(Selection.hot)

            } label: {
                Text("Show")
            }
            .pickerStyle(.segmented)

         
                if listSelection == .search{
                    PodcastSearchView()
                }else{
                   HotPodcastView()
                }
            
               
    }
}

#Preview {
    AddPodcastView()
}
