import Foundation
import SwiftData

actor DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    private var downloads: [URL: DownloadItem] = [:]
    private var urlToTask: [URL: URLSessionDownloadTask] = [:]
    private var destinations: [URL: URL] = [:]
    

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {}

    func download(from url: URL, saveTo destination: URL? = nil, episodeID: UUID? = nil) async -> DownloadItem {
        if let existing = downloads[url] {
            return existing
        }

        let finalDestination = destination ?? defaultDestination(for: url)
        
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

    func item(for episodeID: UUID) async -> DownloadItem? {
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

            try? FileManager.default.removeItem(at: tempCopy)

            if let item = await DownloadManager.shared.getItem(for: url) {
                await MainActor.run {
                    item.isDownloading = false
                    item.isFinished = true
                    print("Download finished for: \(url), isFinished set to true")

                }
                let container = ModelContainerManager().container
                
                let episodeActor = EpisodeActor(modelContainer: container)
                await episodeActor.markEpisodeAvailable(fileURL: url)
                /*
                if let episodeID = await MainActor.run(resultType: UUID?.self, body: { item.episodeID }) {
                    Task.detached {
                        let container = ModelContainerManager().container
                        let modelContext = ModelContext(container)
                        let episodeActor = EpisodeActor(modelContainer: container)
                        await episodeActor.markEpisodeAvailable(episodeID: episodeID)
                        
                        let predicate = #Predicate<EpisodeMetaData> { metadata in
                            // Direct comparison of the episode's persistentModelID
                            metadata.episode?.id == episodeID
                        }

                                do {
                                    let results = try modelContext.fetch(FetchDescriptor<EpisodeMetaData>(predicate: predicate))
                                    guard let metadata = results.first else {
                                        print("❌ No metadata found for episode ID: \(episodeID)")
                                        return
                                    }

                                    metadata.isAvailableLocally = true
                                    try modelContext.save()
                                    print("✅ Metadata updated")
                                } catch {
                                    print("❌ Error fetching or saving metadata: \(error)")
                                }
                    }
                        
                    }
                */
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

