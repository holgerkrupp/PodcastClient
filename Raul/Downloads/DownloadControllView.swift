//
//  DownloadControllView.swift
//  Raul
//
//  Created by Holger Krupp on 09.04.25.
//

import SwiftUI
import Combine

struct DownloadControllView: View {
    @ObservedObject var viewModel = DownloadViewModel()
    let episode: Episode
    @State private var updateUI: Bool = false


    var body: some View {
        VStack {
            if let item = viewModel.item {
                VStack{
                    DownloadProgressView(item: item)
                        .progressViewStyle(CircularProgressViewStyle())
                }

            } else {

                Button {
                    viewModel.startDownload(for: episode)
                    viewModel.startCoverDownload(for: episode)
                    updateUI.toggle()
                } label: {
                    Image(systemName: "arrow.down.circle")
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
