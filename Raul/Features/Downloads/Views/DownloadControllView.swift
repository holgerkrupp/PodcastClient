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
    var showDelete: Bool = true

    var body: some View {
        let downloadedFiles = fileManager.downloadedFiles
        let isDownloaded = isDownloaded(downloadedFiles: downloadedFiles)

        Group {
            if episode.source == .sideLoaded {
                EmptyView()
            } else if let item = viewModel.item {
                DownloadProgressView(item: item, viewModel: viewModel)
                    .progressViewStyle(CircularProgressViewStyle())
            } else if let url = episode.url, isDownloaded == false {
                // Avoid calling actor-isolated API synchronously from the view body.
                // Kick off a task to capture any ongoing download and bind it to the view model.
                let _ = {
                    let currentURL = url
                    Task { @MainActor in
                        if let item = await DownloadManager.shared.getItem(for: currentURL), item.isDownloading {
                            viewModel.setItem(item)
                        }
                    }
                }()

                if let item = viewModel.item, item.isDownloading {
                    DownloadProgressView(item: item, viewModel: viewModel)
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Button {
                        viewModel.startDownload(for: episode)
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
        .labelStyle(.iconOnly)
        .buttonStyle(.glass(.clear))
        .onAppear {
            guard episode.source != .sideLoaded else { return }
            viewModel.observeDownload(for: episode)
            // Fallback: Check for ongoing download in DownloadManager if viewModel.item is nil
            if let url = episode.url {
                Task {
                    if let item = await DownloadManager.shared.getItem(for: url), item.isDownloading {
                        viewModel.setItem(item)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .episodeDownloadFinished).receive(on: DispatchQueue.main)) { notification in
            guard let url = notificationURL(from: notification.userInfo?[EpisodeDownloadNotificationKey.episodeURL]),
                  url == episode.url else { return }
            viewModel.clearFinishedItem(for: url)
            fileManager.refreshDownloadedFiles()
        }
    }

    private func isDownloaded(downloadedFiles: Set<URL>) -> Bool {
        guard episode.source != .sideLoaded else { return true }
        guard let localFile = episode.localFile?.standardizedFileURL else { return false }
        return downloadedFiles.contains(localFile) || episode.metaData?.calculatedIsAvailableLocally == true
    }

    private func notificationURL(from value: Any?) -> URL? {
        if let url = value as? URL {
            return url
        }
        if let url = value as? NSURL {
            return url as URL
        }
        if let string = value as? String {
            return URL(string: string)
        }
        return nil
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
                           
                            .accessibilityHint("Continues the paused download")
                        }else{
                            Button(action: { viewModel.pauseDownload() }) {
                                Label("Pause", systemImage: "pause.circle")
                            }
                           
                            .accessibilityHint("Pauses the active download")
                        }
                        
                        
                    }
                    if !item.isFinished {
                        Button(action: { viewModel.cancelDownload() }) {
                            Label("Cancel", systemImage: "xmark.circle")
                                .foregroundColor(.red)
                        }
                        
                        .accessibilityHint("Stops and removes this download")
                    }
                    
                  
                }
                .buttonStyle(.glass(.clear))
                
            }
        }
    }
}

#Preview {
    let episode = Episode(
        title: "Preview Episode",
        publishDate: Date(),
        url: URL(string: "https://example.com/preview-episode.mp3")!,
        duration: 1_800,
        author: "Preview Author"
    )

    DownloadControllView(episode: episode)
        .padding()
        .environment(DownloadedFilesManager(folder: FileManager.default.temporaryDirectory))
}

#Preview("Partial Download") {
    let item = DownloadItem(url: URL(string: "https://example.com/preview-episode.mp3")!)
    item.isDownloading = true
    item.update(bytesWritten: 36, totalBytes: 100)

    return DownloadProgressView(item: item, viewModel: DownloadViewModel())
        .padding()
}
