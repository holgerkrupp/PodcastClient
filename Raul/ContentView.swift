//
//  ContentView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext


    var body: some View {
        PodcastSearchView()
    }

}

#Preview {
    ContentView()
    //    .modelContainer(for: Item.self, inMemory: true)
}
