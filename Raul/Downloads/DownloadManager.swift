import Foundation
import SwiftData
import UIKit

struct DownloadedFilesManagerReference: @unchecked Sendable {
    weak var manager: DownloadedFilesManager?
}

actor DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    
    private var downloads: [URL: DownloadItem] = [:]
    private var urlToTask: [URL: URLSessionDownloadTask] = [:]
    private var destinations: [URL: URL] = [:]
    private var resumeData: [URL: Data] = [:]
    
    private var downloadedFilesManagerReference: DownloadedFilesManagerReference?

    // MARK: - Inject external manager
    func injectDownloadedFilesManager(_ managerReference: DownloadedFilesManagerReference) {
        downloadedFilesManagerReference = managerReference
    }
    
    // MARK: - Background Session
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.yourapp.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private override init() {}

    private func makeEpisodeActor() async -> EpisodeActor {
        let container = await MainActor.run { ModelContainerManager.shared.container }
        return EpisodeActor(modelContainer: container)
    }

    // MARK: - Public API
    func download(from url: URL, saveTo destination: URL? = nil) async -> DownloadItem? {
        if let existing = downloads[url] {
            return existing
        }
        
        let finalDestination = destination ?? defaultDestination(for: url)
        guard !fileExists(at: finalDestination) else {
            await markDownloaded(for: finalDestination)
            let episodeActor = await makeEpisodeActor()
            await episodeActor.markEpisodeAvailable(fileURL: url)
            return nil
        }
        
        let item = await MainActor.run { DownloadItem(url: url) }
        downloads[url] = item
        destinations[url] = finalDestination
        
        let task = session.downloadTask(with: url)
        urlToTask[url] = task
        await MainActor.run { item.isDownloading = true }
        task.resume()
        
        // Notify the view model that a download has started
        await notifyViewModel(for: url)
        
        return item
    }
    func notifyViewModel(for url: URL) async {
        if let item = downloads[url] {
            await MainActor.run {
                item.isDownloading = true
            }
        }
    }
    
    func cancelDownload(for url: URL) {
        urlToTask[url]?.cancel()
        urlToTask[url] = nil
        downloads[url] = nil
        destinations[url] = nil
        resumeData[url] = nil
    }
    
    func pauseDownload(for url: URL) async {
        guard let task = urlToTask[url] else { return }
        await withCheckedContinuation { continuation in
            task.cancel { data in
                if let data { self.resumeData[url] = data }
                self.urlToTask[url] = nil
                continuation.resume()
            }
        }
    }
    
    func resumeDownload(for url: URL) {
        if let data = resumeData[url] {
            let task = session.downloadTask(withResumeData: data)
            urlToTask[url] = task
            task.resume()
            resumeData.removeValue(forKey: url)
        } else {
            // start fresh if no resume data
            Task { _ = await download(from: url) }
        }
    }
    
    // MARK: - Helpers
    private func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func markDownloaded(for url: URL) async {
        print("markDownloaded: \(url.path)")
        refreshDownloadedFiles()
     //   let episodeActor = await EpisodeActor(modelContainer: ModelContainerManager.shared.container)
     //   await episodeActor.markEpisodeAvailable(fileURL: url)
    }

    private func defaultDestination(for url: URL) -> URL {
        let filename = url.lastPathComponent
        let documents = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent(filename)
    }

    func refreshDownloadedFiles() {
        downloadedFilesManagerReference?.manager?.refreshDownloadedFiles()
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
        print("downloaded \(url.absoluteString)")

        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension)

        do {
            try FileManager.default.copyItem(at: location, to: tempCopy)
        } catch {
            return
        }

        
        
        Task {
            

            
            guard let destination = await DownloadManager.shared.getDestination(for: url) else {
                try? FileManager.default.removeItem(at: tempCopy)
                await DownloadManager.shared.cleanUp(url: url)
                return
            }
            var didStoreFile = false
            do {
                let dir = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempCopy, to: destination)
                didStoreFile = true
            } catch {
                didStoreFile = false
            }

            try? FileManager.default.removeItem(at: tempCopy)

            if didStoreFile {
                let episodeActor = await DownloadManager.shared.makeEpisodeActor()
                await episodeActor.markEpisodeAvailable(fileURL: url)
            }
            
            
            if let item = await DownloadManager.shared.getItem(for: url) {
                print("item received")
                await MainActor.run {
                    item.isDownloading = false
                    item.isFinished = didStoreFile
                }
            }
            await markDownloaded(for: destination)

            await MainActor.run {
                NotificationCenter.default.post(
                    name: .episodeDownloadFinished,
                    object: nil,
                    userInfo: [EpisodeDownloadNotificationKey.episodeURL: url]
                )
            }
            await DownloadManager.shared.cleanUp(url: url)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        guard let url = task.originalRequest?.url else { return }

        Task {
            if let item = await DownloadManager.shared.getItem(for: url) {
                await MainActor.run {
                    item.isDownloading = false
                    item.isFinished = false
                }
            }
            await DownloadManager.shared.cleanUp(url: url)
            print("Download failed for \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
               let completionHandler = appDelegate.backgroundSessionCompletionHandler {
                appDelegate.backgroundSessionCompletionHandler = nil
                completionHandler()
            }
        }
    }

    // MARK: - Internal lookups
    func getItem(for url: URL) -> DownloadItem? { downloads[url] }
    private func getDestination(for url: URL) -> URL? { destinations[url] }

    private func cleanUp(url: URL) async {
        downloads.removeValue(forKey: url)
        urlToTask.removeValue(forKey: url)
        destinations.removeValue(forKey: url)
        resumeData.removeValue(forKey: url)
    }
}
