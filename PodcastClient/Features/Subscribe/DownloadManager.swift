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
        
       
        if let fileURL = episode.assetLink{

            guard downloads[fileURL] == nil else {
                downloads[fileURL]?.resume()
                return }
            let download = Download(url: fileURL, downloadSession: downloadSession)
            downloads[fileURL] = download
            episode.downloadStatus.isDownloading = true
            for await event in download.events {
                await process(event, for: episode)
            }
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
        if !directoryExistsAtPath(url.path()){
            print("create directory at \(url.absoluteString)")
            let filemanager = FileManager.default
            filemanager.delegate = self
            do{
                try filemanager.createDirectory(at: url, withIntermediateDirectories: true)
            }catch{
                print(error)
            }
        }else{
            print(" directory at \(url.absoluteString) exists")
        }
    }
    
    func saveFile(for episode: Episode, at url: URL) {
        let modelContext = ModelContext(PersistanceManager.shared.sharedModelContainer)
   //     guard let episode: Episode = modelContext.model(for: oldepisode.persistentModelID) as? Episode else { return  }
        
        
        
        if let newlocation = episode.localFile{
            print("saving File \(url)")
            print("saving File to \(newlocation)")
            let filemanager = FileManager.default
            filemanager.delegate = self
            
            
            let data = try? Data(contentsOf: url)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var newlocation = newlocation
            
            filemanager.createFile(atPath: newlocation.path, contents: data, attributes: nil)
            try? newlocation.setResourceValues(resourceValues)
         //   createDirectory(at: newlocation.deletingLastPathComponent())
            /*
            do{
                try filemanager.moveItem(at: url, to: newlocation)
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                var url = newlocation
                try url.setResourceValues(resourceValues)

            }catch{
                print(error)
                episode.downloadStatus.isDownloading = false
                if let fileURL = episode.assetLink{
                    downloads.removeValue(forKey: fileURL)
                }
             
            }
            */
            if filemanager.fileExists(atPath: newlocation.path){
                print("available")
                
                episode.isAvailableLocally = true
                episode.downloadStatus.isDownloading = false
                if let fileURL = episode.assetLink{
                    downloads.removeValue(forKey: fileURL)
                }
                Task{
                    await episode.postProcessingAfterDownload()
                }
            }else{
                print("does not exist")
            }

        }

    }
    
    func fileManager(_ fileManager: FileManager, shouldMoveItemAt srcURL: URL, to dstURL: URL) -> Bool {

        
        return true
    }
    
    func fileManager(_ fileManager: FileManager, shouldProceedAfterError error: Error, movingItemAt srcURL: URL, to dstURL: URL) -> Bool {
        print("shouldProceedAfterError")
        print(error)
      
        return true
    }

    
    fileprivate func directoryExistsAtPath(_ path: String) -> Bool {
        var isdirectory : ObjCBool = true
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isdirectory)
        return exists
    }

    
}


extension Podcast {
    var directoryURL: URL {
        URL.documentsDirectory
            .appending(path: "\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "default")", directoryHint: .isDirectory)
    }
}
