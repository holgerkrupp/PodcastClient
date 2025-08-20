//
//  DownloadControllView.swift
//  Raul
//
//  Created by Holger Krupp on 09.04.25.
//

import SwiftUI
import Combine

struct DownloadControllView: View {
    @Environment(DownloadedFilesManager.self) var fileManager

    @ObservedObject var viewModel = DownloadViewModel()
    @State var episode: Episode
    @State private var updateUI: Bool = false
    var showDelete: Bool = true

    // New: This holds a fallback DownloadItem reference for when viewModel.item is nil but an in-progress download exists
    @StateObject private var fallbackDownloadItem = DownloadItem(url: URL(string: "about:blank")!)
    @State private var hasCheckedManager = false

    var body: some View {
        Group {
            
            if let item = viewModel.item {
                
                    DownloadProgressView(item: item, viewModel: viewModel)
                        .progressViewStyle(CircularProgressViewStyle())
                
                
                
            } else if let url = episode.url, fileManager.isDownloaded(episode.localFile) != true {
                
                if let downloadItem = DownloadManager.shared.getItem(for: url), downloadItem.isDownloading {
                  
                    DownloadProgressView(item: downloadItem, viewModel: viewModel)
                        .progressViewStyle(CircularProgressViewStyle())
                }
            
                /*
                else {
                   
                    Button {
                        viewModel.startDownload(for: episode)
                        updateUI.toggle()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
                
                */
            } else {
                
                if showDelete {
                    
                    Button {
                        Task {
                            if let container = episode.modelContext?.container {
                                await EpisodeActor(modelContainer: container).deleteFile(episodeID: episode.id)
                            }
                        }
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                }
            }
        }
        .onAppear {
            viewModel.observeDownload(for: episode)
            // Fallback: Check for ongoing download in DownloadManager if viewModel.item is nil
            if let url = episode.url {
                if let item = DownloadManager.shared.getItem(for: url), item.isDownloading {
                    // Set fallbackDownloadItem to this DownloadItem so progress UI can be shown if needed
                    // Removed assignments to fallbackDownloadItem properties as per instructions
                    // Set viewModel.item as well for better reactivity
                    viewModel.item = item
                }
            }
        }
    }
}

struct DownloadProgressView: View {
    @ObservedObject var item: DownloadItem
    var viewModel: DownloadViewModel

    var body: some View {
        if !item.isFinished {
            VStack {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                HStack {
                Text("\(Int(item.progress * 100))%")
                Spacer()
                    if item.isDownloading {
                        if item.isPaused {
                            Button(action: { viewModel.resumeDownload() }) {
                                Label("Resume", systemImage: "play.circle")
                            }
                            .buttonStyle(.plain)
                        }else{
                            Button(action: { viewModel.pauseDownload() }) {
                                Label("Pause", systemImage: "pause.circle")
                            }
                            .buttonStyle(.plain)
                        }
                        
                        
                    }
                    if !item.isFinished {
                        Button(action: { viewModel.cancelDownload() }) {
                            Label("Cancel", systemImage: "xmark.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    
                  
                }
            }
        }
    }
}
