import Foundation
import Observation


@Observable
 class DownloadedFilesManager {
    private struct WeakObjectBox<Object: AnyObject>: @unchecked Sendable {
        weak var object: Object?
    }

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
        let fileURL = monitoredFolder.appendingPathComponent(fileName).standardizedFileURL
        return downloadedFiles.contains(fileURL)
    }
    

    
    func isDownloaded(_ fileURL: URL?) -> Bool? {
        guard let fileURL else { return nil }
        return downloadedFiles.contains(fileURL.standardizedFileURL)
    }
     
     func deleteAllFiles() throws {
         try? FileManager.default.removeItem(at: monitoredFolder)
     }
      
     func refreshDownloadedFiles() {
        let monitoredFolder = monitoredFolder
        let managerBox = WeakObjectBox(object: self)
         
        queue.async {
            let fileManager = FileManager.default

            let allFiles: [URL] = (fileManager.enumerator(
                at: monitoredFolder,
                includingPropertiesForKeys: nil
            )?.compactMap { $0 as? URL }) ?? []

            let updated: Set<URL> = Set(allFiles.compactMap { url in
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                    return nil
                }
                return url.standardizedFileURL
            })

            
            Task { @MainActor in
                managerBox.object?.downloadedFiles = updated
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
        let managerBox = WeakObjectBox(object: self)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            managerBox.object?.refreshDownloadedFiles()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func rescanDownloadedFiles() {
        refreshDownloadedFiles()
    }
}
