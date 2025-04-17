import Foundation
import Combine
import SwiftData

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var item: DownloadItem?

    func observeDownload(for episode: Episode) {
        Task {
            if let found = await DownloadManager.shared.item(for: episode.persistentModelID) {
                self.item = found
            }
        }
    }

    func startDownload(for episode: Episode, to url: URL) {
        Task {
            let item = await DownloadManager.shared.download(from: url, episode: episode)
            self.item = item
        }
    }
}
