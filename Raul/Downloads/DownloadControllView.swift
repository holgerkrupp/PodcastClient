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

    @StateObject var viewModel = DownloadViewModel()
    @State var episode: Episode
    @State private var updateUI: Bool = false
    var showDelete: Bool = true

    // New: This holds a fallback DownloadItem reference for when viewModel.item is nil but an in-progress download exists
    @StateObject private var fallbackDownloadItem = DownloadItem(url: URL(string: "about:blank")!)
    @State private var hasCheckedManager = false

    var body: some View {
        Group {
            if episode.source == .sideLoaded {
                EmptyView()
            } else if let item = viewModel.item {
                DownloadProgressView(item: item, viewModel: viewModel)
                    .progressViewStyle(CircularProgressViewStyle())
            } else if let url = episode.url, fileManager.isDownloaded(episode.localFile) != true {
                // Avoid calling actor-isolated API synchronously from the view body.
                // Kick off a task to capture any ongoing download and bind it to the view model.
                let _ = {
                    let currentURL = url
                    Task { @MainActor in
                        if let item = await DownloadManager.shared.getItem(for: currentURL), item.isDownloading {
                            viewModel.item = item
                        }
                    }
                }()

                if let item = viewModel.item, item.isDownloading {
                    DownloadProgressView(item: item, viewModel: viewModel)
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Button {
                        viewModel.startDownload(for: episode)
                        updateUI.toggle()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .accessibilityHint("Downloads this episode for offline playback")
                }
            } else if showDelete {
                Button {
                    Task {
                        if let container = episode.modelContext?.container {
                            await EpisodeActor(modelContainer: container).deleteFile(episodeURL: episode.url)
                        }
                    }
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
                .accessibilityHint("Deletes the local file from this device")
            }
        }
        .onAppear {
            guard episode.source != .sideLoaded else { return }
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
                Text("\(item.progress, format: .percent.precision(.fractionLength(0)))")
                Spacer()
                    if item.isDownloading {
                        if item.isPaused {
                            Button(action: { viewModel.resumeDownload() }) {
                                Label("Resume", systemImage: "play.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Continues the paused download")
                        }else{
                            Button(action: { viewModel.pauseDownload() }) {
                                Label("Pause", systemImage: "pause.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Pauses the active download")
                        }
                        
                        
                    }
                    if !item.isFinished {
                        Button(action: { viewModel.cancelDownload() }) {
                            Label("Cancel", systemImage: "xmark.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Stops and removes this download")
                    }
                    
                  
                }
            }
        }
    }
}
