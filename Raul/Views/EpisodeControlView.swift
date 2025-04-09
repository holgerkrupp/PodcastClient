//
//  EpisodeControlView.swift
//  Raul
//
//  Created by Holger Krupp on 07.04.25.
//


import SwiftUI

struct EpisodeControlView: View {
    @State var episode: Episode
    @StateObject private var manager = DownloadManager.shared
    @Environment(\.modelContext) private var modelContext
    @State private var downloadProgress: Double = 0.0
    @State private var isDownloading: Bool = false

    var body: some View {
        HStack {
            if episode.chapters.count > 0 {
                Image(systemName: "list.bullet")
            }
            if episode.transcripts.count > 0 {
                
                    Image(systemName: "text.quote")
                
               
            }
            
         
            
                Spacer()
            
            if let remainingTime = episode.remainingTime,remainingTime != episode.duration, remainingTime > 0 {
                    Text(Duration.seconds(episode.remainingTime ?? 0.0).formatted(.units(width: .narrow)) + " remaining")
                        .font(.caption)
                }else{
                    Text(Duration.seconds(episode.duration ?? 0.0).formatted(.units(width: .narrow)))
                        .font(.caption)
                }
            


            Spacer()
          
            
            if episode.metaData?.isAvailableLocally == true {
                Button {
                    episode.deleteFile()
                } label: {
                    Image(systemName: "trash")
                        .resizable()
                        .scaledToFit()
                }
                .buttonStyle(.bordered)
            } else if manager.downloads[episode.url] != nil {
                VStack(alignment: .trailing) {
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)
                }
                .task {
                    // Start observing download progress
                    let url = episode.url  // Capture URL before async context
                    for await _ in AsyncStream<Void>(unfolding: {
                        if let item = await manager.downloads[url] {
                            await MainActor.run {
                                downloadProgress = item.progress
                                isDownloading = item.isDownloading
                                if let totalBytes = item.totalBytes, totalBytes > 0 {
                                    episode.downloadStatus.update(
                                        currentBytes: Int64(item.progress * Double(totalBytes)),
                                        totalBytes: totalBytes
                                    )
                                }
                            }
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                        return ()
                    }) {
                        // Keep observing
                    }
                }
            } else {
                Button {
                    Task { 
                        if let localFile = episode.localFile {
                            let url = episode.url  // Capture URL before async context
                            episode.downloadStatus.isDownloading = true
                             manager.download(from: url, saveTo: localFile)
                            
                            // Wait for download completion
                            for await _ in AsyncStream<Void>(unfolding: {
                                if await manager.downloads[url] == nil {
                                    await MainActor.run {
                                       
                                        if FileManager.default.fileExists(atPath: localFile.path) {
                                            
                                                episode.markEpisodeAvailable()
                                            
                                            
                                        }
                                    }
                                    return nil
                                }
                                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                                return ()
                            }) {
                                // Keep waiting
                            }
                        }
                    }
                } label: {
                    Image(systemName: "icloud.and.arrow.down")
                        .resizable()
                        .scaledToFit()
                }
                .buttonStyle(.bordered)
                .disabled(episode.downloadStatus.isDownloading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 30)
        .onAppear {

            if let item = manager.downloads[episode.url] {
                print("   Download status: \(item.isDownloading)")
                print("   Progress: \(item.progress)")
            }
        }
    }
}

