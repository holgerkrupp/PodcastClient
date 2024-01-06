import Foundation

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
}

extension Download {
    enum Event {
        case progress(currentBytes: Int64, totalBytes: Int64)
        case success(url: URL)
    }
}

extension Download: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        print("downloading \(totalBytesWritten/totalBytesExpectedToWrite*100)%")
        continuation?.yield(
            .progress(
                currentBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite))
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        print("download Finished")
        continuation?.yield(.success(url: location))
        continuation?.finish()
    }
}


class DownloadManager: NSObject, ObservableObject {
    @Published var podcast: Podcast?
    private var downloads: [URL: Download] = [:]
    
    
    
    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
    }()
    
    static let shared = DownloadManager()

    private override init() {
        super.init()
    }
    
    
    @MainActor
    func download(_ episode: Episode) async throws {
        
        guard episode.asset?.link != nil else { return }
        if let fileURL = episode.asset?.link{
            guard downloads[fileURL] == nil else { return }
            let download = Download(url: fileURL, downloadSession: downloadSession)
            downloads[fileURL] = download
            episode.downloadStatus.isDownloading = true
            for await event in download.events {
                process(event, for: episode)
            }
            downloads[fileURL] = nil
        }else{
            return
        }

    }
    
    func pauseDownload(for episode: Episode) {
        if let fileURL = episode.asset?.link{
            downloads[fileURL]?.pause()
            episode.downloadStatus.isDownloading = false
        }
    }
    
    func resumeDownload(for episode: Episode) {
        if let fileURL = episode.asset?.link{
            downloads[fileURL]?.resume()
            episode.downloadStatus.isDownloading = true
        }
    }
}

private extension DownloadManager {
    func process(_ event: Download.Event, for episode: Episode) {
        switch event {
        case let .progress(current, total):
            episode.downloadStatus.update(currentBytes: current, totalBytes: total)
        case let .success(url):
            saveFile(for: episode, at: url)
        }
    }
    
    func saveFile(for episode: Episode, at url: URL) {

        if let newlocation = episode.localFile{
            print("saving File to \(newlocation)")
            let filemanager = FileManager.default
            episode.downloadStatus.isDownloading = false
            try? filemanager.moveItem(at: url, to: newlocation)
            Task{
                await episode.updateDuration()
            }
            
        }
    }
    

    
}


extension Podcast {
    var directoryURL: URL {
        URL.documentsDirectory
            .appending(path: "\(id)", directoryHint: .isDirectory)
    }
}
