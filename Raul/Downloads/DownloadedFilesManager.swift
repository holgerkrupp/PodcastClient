import Foundation
import Observation


@Observable
 class DownloadedFilesManager {
    private let monitoredFolder: URL
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "DownloadedFilesMonitor") // serial

    private(set) var downloadedFiles: Set<URL> = []

    init(folder: URL) {
        self.monitoredFolder = folder
        refreshDownloadedFiles()
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    func isDownloaded(_ fileName: String) -> Bool {
        let fileURL = monitoredFolder.appendingPathComponent(fileName)
        return downloadedFiles.contains(fileURL)
    }
    

    
    func isDownloaded(_ fileURL: URL?) -> Bool? {
        guard let fileURL else { return nil }

        let standardizedURL = fileURL.standardizedFileURL

        return downloadedFiles.contains(where: { $0.standardizedFileURL == standardizedURL })
    }

     
     func refreshDownloadedFiles() {
         
        queue.async { [weak self] in
            guard let self = self else { return }

            let fileManager = FileManager.default

            let allFiles = (fileManager.enumerator(
                at: monitoredFolder,
                includingPropertiesForKeys: nil
            )?.compactMap { $0 as? URL }) ?? []

            let updated = Set(allFiles.filter { url in
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            })

            
            Task { @MainActor in
                
                self.downloadedFiles = updated
            }
        }
    }

    private func startMonitoring() {
        let fd = open(monitoredFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )

        source.setEventHandler { [weak self]  in
            self?.refreshDownloadedFiles()
        }

        source.setCancelHandler {
            close(fd)
        }

        self.source = source
        source.resume()
    }

    private func stopMonitoring() {
        source?.cancel()
        source = nil
    }
    
    private var pollTimer: Timer?

    func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshDownloadedFiles()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

