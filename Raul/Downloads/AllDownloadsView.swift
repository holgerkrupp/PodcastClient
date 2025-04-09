//
//  AllDownloadsView.swift
//  Raul
//
//  Created by Holger Krupp on 09.04.25.
//

import SwiftUI

struct AllDownloadsView: View {
    
    @StateObject private var manager = DownloadManager.shared
  
    
    var body: some View {
        

        
        List {
            if manager.downloads.isEmpty {
                Text("No downloads")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(manager.downloads.values), id: \.url) { download in
                    DownloadView(url: download.url, downloadItem: download)
                }
            }
        }
        .navigationTitle("Downloads")
    }
}

#Preview {
    AllDownloadsView()
}
