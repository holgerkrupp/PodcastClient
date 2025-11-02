import Foundation
import Observation


@Observable
 class DownloadedFilesManager {
    private let monitoredFolder: URL
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "DownloadedFilesMonitor") // serial

    private(set) var downloadedFiles: Set<URL> = []

    /// Episode IDs inferred from downloaded files. We detect files named like "<UUID>_originalFilename.ext".
    /// This array is kept in sync with `downloadedFiles`.
    private(set) var downloadedEpisodeIDs: [UUID] = []

    /// Extract a UUID prefix from a filename that starts with "<uuid>_".
    private func episodeID(from fileURL: URL) -> UUID? {
        let name = fileURL.lastPathComponent
        // Expect pattern: <uuid>_...
        guard let underscoreIndex = name.firstIndex(of: "_") else { return nil }
        let uuidString = String(name[..<underscoreIndex])
        return UUID(uuidString: uuidString)
    }

    /// Recalculate `downloadedEpisodeIDs` from `downloadedFiles`.
   // @MainActor
    private func updateDownloadedEpisodeIDs() {
        let ids = downloadedFiles.compactMap { episodeID(from: $0) }
        // Preserve stable order by sorting (optional)
        self.downloadedEpisodeIDs = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }

    init(folder: URL) {
        self.monitoredFolder = folder
        refreshDownloadedFiles()
        startMonitoring()
        
        updateDownloadedEpisodeIDs()
        
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
     
     func deleteAllFiles() throws {
         try? FileManager.default.removeItem(at: monitoredFolder)
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
                self.updateDownloadedEpisodeIDs()
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

    /// Returns the current list of episode IDs that have downloaded files.
    func currentDownloadedEpisodeIDs() -> [UUID] {
        return downloadedEpisodeIDs
    }

    /// Forces a rescan of the folder and recomputes episode IDs.
    func rescanDownloadedEpisodeIDs() {
        refreshDownloadedFiles()
        // `updateDownloadedEpisodeIDs()` will be called on main actor after refresh.
    }
}

