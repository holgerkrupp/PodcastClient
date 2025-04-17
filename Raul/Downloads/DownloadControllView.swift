//
//  DownloadControllView.swift
//  Raul
//
//  Created by Holger Krupp on 09.04.25.
//

import SwiftUI

struct DownloadControllView: View {
    @StateObject var viewModel = DownloadViewModel()
    let episode: Episode
    let url: URL

    var body: some View {
        VStack {
            if let item = viewModel.item {
                DownloadProgressView(item: item)

            } else {
                Button("Download") {
                    viewModel.startDownload(for: episode, to: url)
                }
            }
        }
        .onAppear {
            viewModel.observeDownload(for: episode)
        }
        .onReceive(viewModel.$item) { item in
            print("item update")
        }
    }
}

struct DownloadProgressView: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        VStack {
            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
            Text("\(Int(item.progress * 100))%")
        }
    }
}
