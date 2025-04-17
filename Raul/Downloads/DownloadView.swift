//
//  DownloadRowView.swift
//  Raul
//
//  Created by Holger Krupp on 07.04.25.
//


import SwiftUI

struct DownloadView: View {
    let url: URL
    @ObservedObject var downloadItem: DownloadItem

    var body: some View {
        VStack(alignment: .leading) {
  //         Text($downloadItem.episode.title ?? url.lastPathComponent)
          //      .font(.headline)

          
                ProgressView(value: downloadItem.progress)
                    .progressViewStyle(.linear)
                    .padding(.vertical, 4)
                    
            HStack{
                Text("\(downloadItem.downloadedBytes / 1024) KB")
                    .font(.caption)
                Spacer()
                Text("\(Int(downloadItem.progress * 100))%")
                    .font(.caption)
            }

            HStack {
               
                
                if downloadItem.isDownloading {
                  
                    
                    Button {
                        print("⏸️ Pausing download for: \(url)")
                        Task{
                         //   await DownloadManager.shared.pauseDownload(for: url)
                        }
                        } label: {
                        Image(systemName: "pause.circle")
                            .resizable()
                            .scaledToFit()
                    }

                } else {
                    
                    Button {
                        print("▶️ Resuming download for: \(url)")
                        Task{
                       //   await   DownloadManager.shared.resumeDownload(for: url)
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .resizable()
                            .scaledToFit()
                    }
                    
                }
                 
/*
                Button("Cancel") {
                    print("❌ Canceling download for: \(url)")
                    DownloadManager.shared.cancelDownload(for: url)
                }
 */
            }
            .frame(height: 32)
        }
        .padding()
        .onAppear {
            print("📱 DownloadView appeared for URL: \(url)")
            print("   Downloading: \(downloadItem.isDownloading)")
            print("   Progress: \(downloadItem.progress)")
            print("   Downloaded bytes: \(downloadItem.downloadedBytes)")
        }
    }
}
