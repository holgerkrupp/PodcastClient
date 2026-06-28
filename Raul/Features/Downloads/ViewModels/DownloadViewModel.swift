import Foundation
import Combine
import SwiftData

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var item: DownloadItem? 
    private var cancellables: Set<AnyCancellable> = []
    private var itemCancellable: AnyCancellable?

    func observeDownload(for episode: Episode) {
        guard episode.source != .sideLoaded else { return }
        Task {
            if let url = episode.url, let found = await DownloadManager.shared.getItem(for: url) {
                self.setItem(found)
            }
        }

    }

    func startDownload(for episode: Episode) {
        guard episode.source != .sideLoaded else { return }
        Task {
            if let url = episode.url {
                let item = await DownloadManager.shared.download(from: url, saveTo: episode.localFile)
                self.setItem(item)
            }
           
        }
    }

    func setItem(_ item: DownloadItem?) {
        itemCancellable = nil
        guard item?.isFinished != true else {
            self.item = nil
            return
        }

        self.item = item
        itemCancellable = item?.$isFinished
            .sink { [weak self] isFinished in
                guard isFinished else { return }
                Task { @MainActor in
                    self?.item = nil
                }
            }
    }

    func clearFinishedItem(for url: URL) {
        guard item?.url == url, item?.isFinished == true else { return }
        setItem(nil)
    }

    
    func pauseDownload() {
       Task {
            guard let item = item else { return }
           item.isPaused = true
           await DownloadManager.shared.pauseDownload(for: item.url)
        }
    }
    
    func cancelDownload() {
        Task {
            guard let item = item else { return }
            item.isPaused = false
            item.isDownloading = false
            item.isFinished = true
            await DownloadManager.shared.cancelDownload(for: item.url)
        }
    }
    
    func resumeDownload() {
        Task {
            guard let item = item else { return }
            item.isPaused = false
            await DownloadManager.shared.resumeDownload(for: item.url)
        }
    }
    

}
