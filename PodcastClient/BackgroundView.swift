//
//  BackgroundView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 18.02.24.
//

import SwiftUI



struct BackgroundView: View {
    
    
    @Environment(\.modelContext) var modelContext

    
    var body: some View {
        ZStack{
            Rectangle()
                .fill(.red)
            TabBarView()
                .modelContext(modelContext)
        }
    }
}

#Preview {
    BackgroundView()
}
