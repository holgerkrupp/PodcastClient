import Foundation
import Combine
import SwiftUI


@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    weak var episode: Episode?
    
    @Published var isDownloading = false
    @Published var progress: Double = 0.0 // from 0.0 to 1.0
    @Published var totalBytes: Int64?
    @Published var downloadedBytes: Int64 = 0

    init(url: URL, episode: Episode? = nil) {
        self.url = url
        self.episode = episode
    }
}

private actor DownloadStorage {
    var tasks: [URL: URLSessionDownloadTask] = [:]
    var destinations: [URL: URL] = [:]
    
    func getTask(for url: URL) -> URLSessionDownloadTask? {
        tasks[url]
    }
    
    func setTask(_ task: URLSessionDownloadTask?, for url: URL) {
        if let task = task {
            tasks[url] = task
        } else {
            tasks.removeValue(forKey: url)
        }
    }
    
    func getDestination(for url: URL) -> URL? {
        destinations[url]
    }
    
    func setDestination(_ destination: URL?, for url: URL) {
        if let destination = destination {
            destinations[url] = destination
        } else {
            destinations.removeValue(forKey: url)
        }
    }
}

@MainActor
class DownloadManager: NSObject, ObservableObject, URLSessionDelegate, URLSessionDownloadDelegate {
    // Mark as @MainActor to ensure thread safety for UI updates
    @Published private(set) var downloads: [URL: DownloadItem] = [:]
    static let shared = DownloadManager() 
    
    private let storage = DownloadStorage()
    private var resumeData: [URL: Data] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()
    
    override private init() {
        super.init()
    }

    func download(from url: URL, saveTo destination: URL? = nil, episode: Episode? = nil) {
        let finalDestination = destination ?? defaultDestination(for: url)
        
        // Create the destination directory if it doesn't exist
        let folderURL = finalDestination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
        
        Task { @MainActor in
            guard downloads[url] == nil else {
                resumeDownload(for: url)
                return
            }

            let item = DownloadItem(url: url, episode: episode)
            downloads[url] = item

            let task = session.downloadTask(with: url)
            await storage.setTask(task, for: url)
            await storage.setDestination(finalDestination, for: url)

            item.isDownloading = true
            episode?.downloadStatus.isDownloading = true
            task.resume()
        }
    }

    func pauseDownload(for url: URL) {
        Task {
            if let task = await storage.getTask(for: url) {
                task.suspend()
                let downloadItem = downloads[url]
                downloadItem?.isDownloading = false
            }
        }
    }

    func resumeDownload(for url: URL) {
        Task {
            if let task = await storage.getTask(for: url) {
                task.resume()
                let downloadItem = downloads[url]
                downloadItem?.isDownloading = true
            }
        }
    }

    func cancelDownload(for url: URL) {
        Task {
            if let task = await storage.getTask(for: url) {
                task.cancel()
            }
            await storage.setTask(nil, for: url)
            await storage.setDestination(nil, for: url)
            await MainActor.run { _ = downloads.removeValue(forKey: url) }
        }
    }

    private func saveDownloadedFile(from tempURL: URL, to destination: URL) async throws {
      
        
        let fileManager = FileManager.default
        
        // Ensure the destination directory exists
        let dir = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        
        // Remove existing file if it exists
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        
        // Copy the file instead of moving it
        try fileManager.copyItem(at: tempURL, to: destination)
        
        // Set file attributes
        var mutableDestination = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableDestination.setResourceValues(values)
        
    }

    private func defaultDestination(for url: URL) -> URL {
        let filename = url.lastPathComponent
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return directory.appendingPathComponent(filename)
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        

        guard let url = downloadTask.originalRequest?.url else { 
            return
        }

        Task { @MainActor in
            guard let item = downloads[url] else { 
                return
            }
            item.downloadedBytes = totalBytesWritten
            item.totalBytes = totalBytesExpectedToWrite
            if totalBytesExpectedToWrite > 0 {
                item.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                
                // Update episode download status
                if let episode = item.episode {
                    episode.downloadStatus.update(currentBytes: totalBytesWritten, totalBytes: totalBytesExpectedToWrite)
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
      

        guard let url = downloadTask.originalRequest?.url else { 
            print("❌ Missing URL")
            return 
        }

        // Immediately copy the temporary file
        let tempCopyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension)
        
       
        
        do {
            try FileManager.default.copyItem(at: location, to: tempCopyURL)
        } catch {
            print("❌ Error copying temporary file: \(error)")
            return
        }

        Task {
            guard let destination = await storage.getDestination(for: url) else {
                print("❌ Missing destination")
                try? FileManager.default.removeItem(at: tempCopyURL)
                return
            }

            do {
                try await saveDownloadedFile(from: tempCopyURL, to: destination)
                print("✅ File saved successfully to: \(destination)")
            } catch {
                print("❌ Error saving file: \(error)")
            }
            
            // Clean up our temporary copy
            try? FileManager.default.removeItem(at: tempCopyURL)

            await MainActor.run {
                downloads[url]?.isDownloading = false
                downloads.removeValue(forKey: url)
            }
            await storage.setTask(nil, for: url)
            await storage.setDestination(nil, for: url)
            print("✅ Cleanup completed for URL: \(url)")
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("❌ Download failed with error: \(error)")
            if let url = task.originalRequest?.url {
                Task {
                    // Check if this was a cancellation with resume data
                    if let downloadTask = task as? URLSessionDownloadTask,
                       let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        await MainActor.run {
                            self.resumeData[url] = resumeData
                            downloads[url]?.isDownloading = false
                        }
                        print("✅ Stored resume data for paused download")
                    } else {
                        // This was a real error or cancellation without resume data
                        await MainActor.run {
                            downloads[url]?.isDownloading = false
                            downloads.removeValue(forKey: url)
                        }
                        await storage.setTask(nil, for: url)
                        await storage.setDestination(nil, for: url)
                    }
                }
            }
        }
    }
}
