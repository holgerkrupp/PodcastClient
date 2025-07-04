import Foundation
import SwiftData

actor DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    private var downloads: [URL: DownloadItem] = [:]
    private var urlToTask: [URL: URLSessionDownloadTask] = [:]
    private var destinations: [URL: URL] = [:]
    

    private var downloadedFilesManager: DownloadedFilesManager?

    func injectDownloadedFilesManager(_ manager: DownloadedFilesManager) {
        self.downloadedFilesManager = manager
    }
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {}

    func download(from url: URL, saveTo destination: URL? = nil, episodeID: UUID? = nil) async -> DownloadItem? {
        if let existing = downloads[url] {
            print(">>> Reusing existing download for %{public}@\n", url.absoluteString)
            return existing
        }


        let finalDestination = destination ?? defaultDestination(for: url)
        
        print(fileExists(at: finalDestination) ? "file exists: \(finalDestination)" : "file does not exists: \(finalDestination)")
        
        guard !fileExists(at: finalDestination) else {
            print("file does exists: \(finalDestination)")
            await markDownloaded(for: url)
            return nil
        }
        
        let item = await MainActor.run {
            
            DownloadItem(url: url, episodeID: episodeID)
        }
        downloads[url] = item
        destinations[url] = finalDestination

        let task = session.downloadTask(with: url)
        urlToTask[url] = task
        await MainActor.run { item.isDownloading = true }
        task.resume()
        return item
    }

    
    func cancelDownload(for url: URL)  {
        print("cancel Download \(url)")
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

    private func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
    private func markDownloaded(for url: URL) async {
        guard let container = ModelContainerManager().container else {
            print("Warning: Could not mark Downloaded because ModelContainer is nil.")
            return
        }
        refreshDownloadedFiles()
        let episodeActor = EpisodeActor(modelContainer: container)
        await episodeActor.markEpisodeAvailable(fileURL: url)
      //  await episodeActor.updateDuration(fileURL: url)
    }
    

    
    private func markPurgeable(for url: URL) async {
        // For a file at `url`:
        var url = url
        var resourceValues = URLResourceValues()

        resourceValues.isExcludedFromBackup = true
        try? url.setResourceValues(resourceValues)
    }
    
    private func defaultDestination(for url: URL) -> URL {
        let filename = url.lastPathComponent
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent(filename)
    }
    
    func refreshDownloadedFiles() {
        downloadedFilesManager?.refreshDownloadedFiles()
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
        print("finished Download \(url) ")

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

        Task {
            guard let destination = await DownloadManager.shared.getDestination(for: url) else {
                
                print("cant find destination for \(url)")
                
                return }
            print("move file to \(destination)")
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

            try? FileManager.default.removeItem(at: tempCopy)

            if let item = await DownloadManager.shared.getItem(for: url) {
                await MainActor.run {
                    item.isDownloading = false
                    item.isFinished = true
                    print("Download finished for: \(url), isFinished set to true")
                    
                }
                
                await markDownloaded(for: url)

                }
                
            


            await DownloadManager.shared.cleanUp(url: url)
        }
    }

     func getItem(for url: URL) -> DownloadItem? {
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

