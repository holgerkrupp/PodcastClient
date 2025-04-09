//
//  DownloadControllView.swift
//  Raul
//
//  Created by Holger Krupp on 09.04.25.
//

import SwiftUI

struct DownloadControllView: View {
    @StateObject private var manager = DownloadManager.shared

    @State var url: URL
    var body: some View {
        if let download = manager.downloads[url] {
            HStack {
                Button {
                 //   manager.cancelDownload(for: download.url)
                } label: {
                    Image(systemName: "xmark.bin.circle")
                        .resizable()
                        .scaledToFit()
                }
                Spacer()
               
                if download.isDownloading {
                    Button {
                        manager.pauseDownload(for: download.url)
                    } label: {
                        Image(systemName: "pause.circle")
                            .resizable()
                            .scaledToFit()
                    }
                } else {
                    Button {
                        manager.resumeDownload(for: download.url)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .resizable()
                            .scaledToFit()
                    }
                }
             //   .buttonStyle(.bordered)
            }
            .frame(height: 44)
        }
        

    }
}



#Preview {
    let download: DownloadItem = .init(url: URL(string: String("https://example.com/test.pdf"))!, episode: nil)
    
    DownloadControllView(url: URL(string: String("https://example.com/test.pdf"))!)
}
