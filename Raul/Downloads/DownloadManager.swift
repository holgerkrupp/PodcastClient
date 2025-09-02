import Foundation
import SwiftData
import UIKit

actor DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    
    private var downloads: [URL: DownloadItem] = [:]
    private var urlToTask: [URL: URLSessionDownloadTask] = [:]
    private var destinations: [URL: URL] = [:]
    private var resumeData: [URL: Data] = [:]
    
    private var downloadedFilesManager: DownloadedFilesManager?

    // MARK: - Inject external manager
    func injectDownloadedFilesManager(_ manager: DownloadedFilesManager) {
        self.downloadedFilesManager = manager
    }
    
    // MARK: - Background Session
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.yourapp.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private override init() {}

    // MARK: - Public API
    func download(from url: URL, saveTo destination: URL? = nil, episodeID: UUID? = nil) async -> DownloadItem? {
        if let existing = downloads[url] {
            return existing
        }

        let finalDestination = destination ?? defaultDestination(for: url)
        guard !fileExists(at: finalDestination) else {
            await markDownloaded(for: finalDestination)
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
        refreshDownloadedFiles()
        let episodeActor = await EpisodeActor(modelContainer: ModelContainerManager.shared.container)
        await episodeActor.markEpisodeAvailable(fileURL: url)
    }

    private func defaultDestination(for url: URL) -> URL {
        let filename = url.lastPathComponent
        let documents = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
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

        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension)

        do {
            try FileManager.default.copyItem(at: location, to: tempCopy)
        } catch {
            return
        }

        Task {
            guard let destination = await DownloadManager.shared.getDestination(for: url) else { return }
            do {
                let dir = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: tempCopy, to: destination)
            } catch {}

            try? FileManager.default.removeItem(at: tempCopy)

            if let item = await DownloadManager.shared.getItem(for: url) {
                await MainActor.run {
                    item.isDownloading = false
                    item.isFinished = true
                }
                await markDownloaded(for: destination)
            }
            await DownloadManager.shared.cleanUp(url: url)
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
