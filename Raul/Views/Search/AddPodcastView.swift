//
//  AddPodcastView.swift
//  Raul
//
//  Created by Holger Krupp on 03.04.25.
//

import SwiftUI

struct AddPodcastView: View {
    @Environment(\.modelContext) private var context
    @Binding var search: String
    enum Selection {
        case search, hot, importexport
    }
    @State private var listSelection:Selection = .search
    var body: some View {
        NavigationStack{
            List{
            
                NavigationLink(destination: ImportExportView()
                    .modelContext(context)) {
                    HStack {
                        Text("Import / Export")
                            .font(.headline)

                    }
                }
                NavigationLink(destination:  PodcastCategoryView()
                    .modelContext(context)) {
                    HStack {
                        Text("Browse by Category")
                            .font(.headline)

                    }
                }
               
                
             
                    PodcastSearchView(search: $search)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))

            }
            .listStyle(.plain)

            
            
        }
       
    }
}

#Preview {
    @Previewable @State var search: String = ""
    AddPodcastView(search: $search)
}
