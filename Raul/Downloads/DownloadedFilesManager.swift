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
        print("isDownloaded fileURL: \(String(describing: fileURL))")
        dump(downloadedFiles)
        guard let fileURL else { return nil }
        return downloadedFiles.contains(fileURL)
    }

    private func refreshDownloadedFiles() {
        queue.async { [weak self] in
            guard let self else { return }

            let fileManager = FileManager.default
            let allFiles = (try? fileManager.contentsOfDirectory(at: self.monitoredFolder, includingPropertiesForKeys: nil)) ?? []
            let updated = Set(allFiles)

            // Update observable state on the main thread
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

        source.setEventHandler { [weak self] in
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
}
