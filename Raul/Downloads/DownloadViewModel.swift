import Foundation
import Combine
import SwiftData

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var item: DownloadItem? 
    private var cancellables: Set<AnyCancellable> = []

    func observeDownload(for episode: Episode) {
        Task {
            if let found = await DownloadManager.shared.item(for: episode.persistentModelID) {
                self.item = found
            }
        }
//        Task { @MainActor in
//            if let item = item {
//                item.objectWillChange
//                    .sink { [weak self] in
//                        if item.isFinished {
//                            self?.item = nil
//                        }
//                    }
//                    .store(in: &self.cancellables)
//            }
//        }
    }

    func startDownload(for episode: Episode) {
        Task {
            let item = await DownloadManager.shared.download(from: episode.url, saveTo: episode.localFile, episode: episode)
            self.item = item
        }
    }
    
    func pauseDownload() {
       Task {
            guard let item = item else { return }
           await DownloadManager.shared.pauseDownload(for: item.url)
        }
    }
    
    func cancelDownload() {
        Task {
            guard let item = item else { return }
            await DownloadManager.shared.cancelDownload(for: item.url)
        }
    }
    
    func resumeDownload() {
        Task {
            guard let item = item else { return }
            await DownloadManager.shared.resumeDownload(for: item.url)
        }
    }
    

}
