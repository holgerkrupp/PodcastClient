//
//  AddPodcastView.swift
//  Raul
//
//  Created by Holger Krupp on 03.04.25.
//

import SwiftUI

struct AddPodcastView: View {
    @Environment(\.modelContext) private var context

    enum Selection {
        case search, hot, importexport
    }
    @State private var listSelection:Selection = .search
    var body: some View {
        NavigationStack{
            Picker(selection: $listSelection) {
                Text("Search").tag(Selection.search)
                Text("Hot").tag(Selection.hot)
                Text("Import").tag(Selection.importexport)
            } label: {
                Text("Show")
            }
            .pickerStyle(.segmented)
            
            switch listSelection {
            case .search:
                PodcastSearchView()
            case .hot:
                HotPodcastView()
          
            case .importexport:
                ImportExportView()
                    .modelContext(context)
            }
            
            
            
            
        }
    }
}

#Preview {
    AddPodcastView()
}
