import Foundation
import Combine
import SwiftData

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var item: DownloadItem? 
    private var cancellables: Set<AnyCancellable> = []

    func observeDownload(for episode: Episode) {
        Task {
            if let found = await DownloadManager.shared.item(for: episode.id) {
                self.item = found
            }
        }

    }

    func startDownload(for episode: Episode) {
        Task {
            let item = await DownloadManager.shared.download(from: episode.url, saveTo: episode.localFile, episodeID: episode.id)
            self.item = item
          //  print("started download for \(episode.title)")
            
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
