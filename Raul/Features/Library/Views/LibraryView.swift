//
//  LibraryView.swift
//  Raul
//
//  Created by Holger Krupp on 29.05.25.
//

import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    

    
    var body: some View {
        PodcastListView(modelContainer: context.container)
    }
    
}

#Preview {
    LibraryView()
}
