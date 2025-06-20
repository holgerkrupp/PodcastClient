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


    var body: some View {
        Group {
            if let item = viewModel.item {
                    DownloadProgressView(item: item)
                        .progressViewStyle(CircularProgressViewStyle())
            } else {
                
                if fileManager.isDownloaded(episode.localFile) != true {
                    Button {
                        viewModel.startDownload(for: episode)
                        viewModel.startCoverDownload(for: episode)
                        updateUI.toggle()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    
                }else{
                    Button{
                        Task{
                            if let container = episode.modelContext?.container{
                               await EpisodeActor(modelContainer: container).deleteFile(episodeID: episode.id)
                            }
                        }
                    }label:{
                        Label("Remove Download", systemImage: "trash")

                    }
                }
            }
        }
        .onAppear {
            viewModel.observeDownload(for: episode)
       
        }
    }
}

struct DownloadProgressView: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        if !item.isFinished {
            VStack {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                Text("\(Int(item.progress * 100))%")

            }
            
        }

    }
}
