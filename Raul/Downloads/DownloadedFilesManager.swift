import Foundation
import Observation


@Observable
 class DownloadedFilesManager {
    private struct WeakObjectBox<Object: AnyObject>: @unchecked Sendable {
        weak var object: Object?
    }

    private static let managedDownloadPrefixLength = 64
    private static let managedDownloadHashCharacters = Set("0123456789abcdef")

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
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]

        queue.async {
            let fileManager = FileManager.default
            let allEntries = (try? fileManager.contentsOfDirectory(
                at: monitoredFolder,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )) ?? []

            let updated = Set<URL>(allEntries.compactMap { url in
                guard Self.isManagedDownloadFile(url) else { return nil }
                guard let isRegularFile = try? url.resourceValues(forKeys: resourceKeys).isRegularFile,
                      isRegularFile == true else {
                    return nil
                }
                return url.standardizedFileURL
            })

            
            Task { @MainActor in
                managerBox.object?.downloadedFiles = updated
            }
        }
    }

    private static func isManagedDownloadFile(_ url: URL) -> Bool {
        let fileName = url.lastPathComponent
        guard let separatorIndex = fileName.index(
            fileName.startIndex,
            offsetBy: managedDownloadPrefixLength,
            limitedBy: fileName.endIndex
        ),
        separatorIndex < fileName.endIndex,
        fileName[separatorIndex] == "_" else {
            return false
        }

        return fileName[..<separatorIndex].allSatisfy { managedDownloadHashCharacters.contains($0) }
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
