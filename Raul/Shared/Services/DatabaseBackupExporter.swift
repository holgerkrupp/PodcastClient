import Foundation
import BasicLogger

// Development-only. Staging copies of every store under `Library` is a support
// affordance, not a user feature: the copies are unencrypted-at-rest duplicates
// of the whole library. See the precondition on `ModelContainerManager`'s
// recovery section.
#if DEBUG
struct DatabaseBackupExportResult: Sendable {
    var directoryName: String = ""
    var copiedFiles: [String] = []
    var failures: [String] = []

    var summary: String {
        if copiedFiles.isEmpty {
            return "Nothing copied. \(failures.joined(separator: "; "))"
        }
        var text = "Exported \(copiedFiles.count) files to Library/\(directoryName)."
        if failures.isEmpty == false {
            text += " Failed: \(failures.joined(separator: "; "))"
        }
        return text
    }
}

/// Copies the SQLite stores into the app group's `Library` directory.
///
/// The stores themselves live at the group container root, which the device file
/// service refuses to hand out — only `Library`, `Documents` and `tmp` are
/// readable from a Mac. Staging a copy under `Library` is what makes
/// `xcrun devicectl device copy from` able to pull a backup off the phone.
enum DatabaseBackupExporter {
    /// Copies every store plus its `-wal`/`-shm` sidecars. The sidecars matter:
    /// a `.sqlite` taken without them can be missing the most recent
    /// transactions, which is precisely the data worth rescuing here.
    private static let sidecarSuffixes = ["", "-wal", "-shm"]

    static func exportStores() -> DatabaseBackupExportResult {
        var result = DatabaseBackupExportResult()

        guard let containerURL = ModelContainerManager.sharedContainerURL else {
            result.failures.append("app group container unavailable")
            return result
        }

        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        result.directoryName = "DatabaseBackup-\(stamp)"
        let destination = containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(result.directoryName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        } catch {
            result.failures.append("create directory: \(error.localizedDescription)")
            return result
        }

        let stores = [
            ModelContainerManager.sharedStoreURL,
            ModelContainerManager.userStateStoreURL,
            ModelContainerManager.cacheStoreURL
        ].compactMap { $0 }

        for store in stores {
            for suffix in sidecarSuffixes {
                let source = store.deletingLastPathComponent()
                    .appendingPathComponent(store.lastPathComponent + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let target = destination.appendingPathComponent(source.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: source, to: target)
                    result.copiedFiles.append(source.lastPathComponent)
                } catch {
                    result.failures.append(
                        "\(source.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
        }

        let summary = result.summary
        Task { @MainActor in BasicLogger.shared.log("[Backup] \(summary)") }
        return result
    }
}
#endif
