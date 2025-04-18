import Foundation
import SwiftData

actor DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    private var downloads: [URL: DownloadItem] = [:]
    private var urlToTask: [URL: URLSessionDownloadTask] = [:]
    private var destinations: [URL: URL] = [:]
    private var episodes: [URL: PersistentIdentifier] = [:]
    

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {}

    func download(from url: URL, saveTo destination: URL? = nil, episode: Episode? = nil) async -> DownloadItem {
        if let existing = downloads[url] {
            return existing
        }

        let finalDestination = destination ?? defaultDestination(for: url)
        let episodeID = episode?.persistentModelID
        let item = await MainActor.run {
            
            DownloadItem(url: url, episodeID: episodeID)
        }
        downloads[url] = item
        destinations[url] = finalDestination
        episodes[url] = episode?.persistentModelID

        let task = session.downloadTask(with: url)
        urlToTask[url] = task
        await MainActor.run { item.isDownloading = true }
        task.resume()
        return item
    }

    /// 🔄 Fix: This version hops to main actor to safely compare `episodeID`
    func item(for episodeID: PersistentIdentifier) async -> DownloadItem? {
        let allItems = Array(downloads.values)
        for item in allItems {
            if await MainActor.run(resultType: Bool.self, body: {
                item.episodeID == episodeID
            }) {
                return item
            }
        }
        return nil
    }
    
    func cancelDownload(for url: URL)  {
        urlToTask[url]?.cancel()
        urlToTask[url] = nil
        downloads[url] = nil
        destinations[url] = nil
    }
    
    func pauseDownload(for url: URL) {
        urlToTask[url]?.suspend()
    }
    
    func resumeDownload(for url: URL) {
        urlToTask[url]?.resume()
    }

    private func defaultDestination(for url: URL) -> URL {
        let filename = url.lastPathComponent
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent(filename)
    }

    // MARK: - Delegate

    nonisolated func urlSession(_ session: URLSession,
                                 downloadTask: URLSessionDownloadTask,
                                 didWriteData bytesWritten: Int64,
                                 totalBytesWritten: Int64,
                                 totalBytesExpectedToWrite: Int64) {
        guard let url = downloadTask.originalRequest?.url else { return }

        Task {
            if let item = await DownloadManager.shared.getItem(for: url) {
                await MainActor.run {
                    item.update(bytesWritten: totalBytesWritten, totalBytes: totalBytesExpectedToWrite)
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                 downloadTask: URLSessionDownloadTask,
                                 didFinishDownloadingTo location: URL) {
        guard let url = downloadTask.originalRequest?.url else { return }

        // Create a safe temp location to copy the file to before we suspend
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension)

        do {
            try FileManager.default.copyItem(at: location, to: tempCopy)
        } catch {
            print("❌ Immediate copy failed: \(error)")
            return
        }

        // Now you're safe to suspend or async call
        Task {
            guard let destination = await DownloadManager.shared.getDestination(for: url) else { return }

            do {
                // Make sure directory exists
                let dir = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                // Final copy to destination
                try FileManager.default.copyItem(at: tempCopy, to: destination)
                print("✅ File copied to: \(destination)")

            } catch {
                print("❌ Save error: \(error)")
            }

            // Clean up temp copy
            try? FileManager.default.removeItem(at: tempCopy)

            if let item = await DownloadManager.shared.getItem(for: url) {
                await MainActor.run {
                    item.isDownloading = false
                    item.isFinished = true
                    print("Download finished for: \(url), isFinished set to true")

                }
            }

            await DownloadManager.shared.cleanUp(url: url)
        }
    }

    private func getItem(for url: URL) -> DownloadItem? {
        return downloads[url]
    }

    private func getDestination(for url: URL) -> URL? {
        return destinations[url]
    }

    private func cleanUp(url: URL) async {
        
        downloads.removeValue(forKey: url)
        urlToTask.removeValue(forKey: url)
        destinations.removeValue(forKey: url)
        
        print("downloads: \(downloads.count) - destinations: \(destinations.count) - urlToTask: \(urlToTask.count)")
        print("\(url.lastPathComponent) in downloads: \(await downloads[url]?.progress ?? 0)")
    }
    
}

