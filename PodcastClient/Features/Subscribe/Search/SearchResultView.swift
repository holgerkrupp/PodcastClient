//
//  ITunesResultView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 04.02.24.
//

import SwiftUI

struct SearchResultView: View {
    @State var searchResults:[PodcastFeed] = []
    
    var subscriptionManager = SubscriptionManager.shared
    
    var body: some View {
        
        
       
            ForEach(searchResults, id:\.self){ podcast in
                SubscribeToView(newPodcastFeed: podcast)
            }
        }
    
}

#Preview {
    SearchResultView()
}



