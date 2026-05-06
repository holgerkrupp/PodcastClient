//
//  PlayerEmptyView.swift
//  Raul
//
//  Created by Holger Krupp on 28.05.25.
//

import SwiftUI

struct PlayerEmptyView: View {
    var body: some View {
        HStack{
            Spacer()
            Text("No episode playing.")
            Spacer()
        }
    }
}

#Preview {
    PlayerEmptyView()
}
