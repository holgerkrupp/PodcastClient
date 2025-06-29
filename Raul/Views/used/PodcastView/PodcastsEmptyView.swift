//
//  InboxEmptyView.swift
//  Raul
//
//  Created by Holger Krupp on 18.05.25.
//

import SwiftUI

struct InboxEmptyView: View {
    var body: some View {
        VStack{
            Text("Your Inbox is empty")
                .font(.headline)
            Divider()
            Text("New episodes of subscribed podcasts appear here. You can add them to your listening queue or archive them, if you are not interested in an episode.")
        }
        .padding()
    }
}

#Preview {
    InboxEmptyView()
}
