import Foundation
import SwiftData

class Download: NSObject {
    let url: URL
    let downloadSession: URLSession
    
    private var continuation: AsyncStream<Event>.Continuation?
    
    private lazy var task: URLSessionDownloadTask = {
        let task = downloadSession.downloadTask(with: url)
        task.delegate = self
        return task
    }()
    
    init(url: URL, downloadSession: URLSession) {
        self.url = url
        self.downloadSession = downloadSession
    }
    
    var isDownloading: Bool {
        task.state == .running
    }
    
    var events: AsyncStream<Event> {
        AsyncStream { continuation in
            self.continuation = continuation
            task.resume()
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.task.cancel()
            }
        }
    }
    
    func pause() {
        task.suspend()
    }
    
    func resume() {
        task.resume()
    }
    
    func cancel(){
        task.cancel()
    }
}

extension Download {
    enum Event {
        case progress(currentBytes: Int64, totalBytes: Int64)
        case success(url: URL)
    }
}

extension Download: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        continuation?.yield(
            .progress(
                currentBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite))
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        continuation?.yield(.success(url: location))
        continuation?.finish()
    }
}


class DownloadManager: NSObject, ObservableObject {
   // @Published var podcast: Podcast?
    private var downloads: [URL: Download] = [:]
    
    
    
    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
    }()
    
    static let shared = DownloadManager()

    private override init() {
        super.init()
    }
    
    
    //@MainActor
    func download(_ episode: Episode) async throws {
        
        guard episode.assetLink != nil else { return }
        if let fileURL = episode.assetLink{
            guard downloads[fileURL] == nil else { return }
            let download = Download(url: fileURL, downloadSession: downloadSession)
            downloads[fileURL] = download
            episode.downloadStatus.isDownloading = true
            for await event in download.events {
                await process(event, for: episode)
            }
            downloads[fileURL] = nil
        }else{
            return
        }

    }
    
    func pauseDownload(for episode: Episode) {
        if let fileURL = episode.assetLink{
            downloads[fileURL]?.pause()
            episode.downloadStatus.isDownloading = false
        }
    }
    
    func resumeDownload(for episode: Episode) {
        if let fileURL = episode.assetLink{
            downloads[fileURL]?.resume()
            episode.downloadStatus.isDownloading = true
        }
    }
    
    func cancelDownload(for episode: Episode) {
        if let fileURL = episode.assetLink{
            downloads[fileURL]?.cancel()
            episode.downloadStatus.isDownloading = false
            downloads.removeValue(forKey: fileURL)
        }
    }
    
}

extension DownloadManager: FileManagerDelegate {
    func process(_ event: Download.Event, for episode: Episode) async {
        switch event {
        case let .progress(current, total):
            episode.downloadStatus.update(currentBytes: current, totalBytes: total)
           
        case let .success(url):
            saveFile(for: episode, at: url)
            
        }
    }
    
    func createDirectory(at url: URL){
        print("create directory at \(url.absoluteString)")
        let filemanager = FileManager.default
        filemanager.delegate = self
        do{
            try filemanager.createDirectory(at: url, withIntermediateDirectories: true)
        }catch{
            print(error)
        }
    }
    
    func saveFile(for episode: Episode, at url: URL) {

        if let newlocation = episode.localFile{
            print("saving File \(url)")
            print("saving File to \(newlocation)")
            let filemanager = FileManager.default
            filemanager.delegate = self
            createDirectory(at: newlocation.deletingLastPathComponent())
            
            do{
                try filemanager.moveItem(at: url, to: newlocation)
                

            }catch{
                print(error)
                episode.downloadStatus.isDownloading = false

             
            }
            
            if filemanager.fileExists(atPath: newlocation.path){
                episode.isAvailableLocally = true
                episode.downloadStatus.isDownloading = false
                
                Task{
                    await episode.postProcessingAfterDownload()
                }
            }else{
                episode.isAvailableLocally = false
                episode.downloadStatus.isDownloading = false
            }

        }

    }
    
    func fileManager(_ fileManager: FileManager, shouldMoveItemAt srcURL: URL, to dstURL: URL) -> Bool {
        if fileManager.fileExists(atPath: dstURL.path()){
            print("shouldMoveItemAt")
            do{
                try fileManager.removeItem(at: dstURL)
            }catch{
                print(error)
                return false
            }
        }
        
        return true
    }
    
    func fileManager(_ fileManager: FileManager, shouldProceedAfterError error: Error, movingItemAt srcURL: URL, to dstURL: URL) -> Bool {
        print("shouldProceedAfterError")
        print(error)
        return true
    }

    
  

    
}


extension Podcast {
    var directoryURL: URL {
        URL.documentsDirectory
            .appending(path: "\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "default")", directoryHint: .isDirectory)
    }
}