//
//  CreatedByView.swift
//  Raul
//
//  Created by Holger Krupp on 22.08.25.
//

import SwiftUI

struct CreatedByView: View {
    var body: some View {
        VStack(alignment: .center, spacing:10){
            if let url = URL(string: "https://extremelysuccessfulapps.com"){
                Text("Created in Buxtehude by")
                Link(destination: url) {
                    Label("Extremely Successful Apps", image: "extremelysuccessfullogo")
                        .tint(.accent)
                }
                
                if let gitURL = URL(string: "https://github.com/holgerkrupp/PodcastClient"){
                    Divider()
                    Link(destination: gitURL) {
                        Label("Get the source code", image: "githublogo")
                            .tint(.accent)
                    }
                }
            }
            VersionNumberView()
                .font(.caption)
        }
    }
}

#Preview {
    CreatedByView()
}
