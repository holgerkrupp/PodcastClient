import CryptoKit
import Foundation
import SQLite3
import SwiftUI
import UniformTypeIdentifiers

/// A self-contained, restorable snapshot of Up Next's two authoritative stores.
/// Downloads, Keychain credentials, app preferences, and historical migration
/// stores are intentionally excluded; a restore must describe those limits.
struct RestorableLibraryBackupDocument: FileDocument, @unchecked Sendable {
    static let contentType = UTType(
        exportedAs: "de.holgerkrupp.upnext.library-backup",
        conformingTo: .package
    )
    static var readableContentTypes: [UTType] { [contentType] }

    private var package: FileWrapper

    init(sharedDatabaseURL: URL, userStateDatabaseURL: URL) throws {
        let packageURL = try RestorableLibraryBackupArchive.create(
            sharedDatabaseURL: sharedDatabaseURL,
            userStateDatabaseURL: userStateDatabaseURL
        )
        package = try FileWrapper(url: packageURL, options: .immediate)
    }

    init(packageURL: URL) throws {
        package = try FileWrapper(url: packageURL, options: .immediate)
        try RestorableLibraryBackupArchive.validate(fileWrapper: package)
    }

    init(configuration: ReadConfiguration) throws {
        guard configuration.file.isDirectory else {
            throw RestorableLibraryBackupError.invalidPackage
        }
        package = configuration.file
        try RestorableLibraryBackupArchive.validate(fileWrapper: package)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        package
    }
}

enum RestorableLibraryBackupError: LocalizedError {
    case sourceUnavailable(String)
    case invalidPackage
    case unsupportedVersion(Int)
    case checksumMismatch(String)
    case invalidDatabase(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let name):
            "The \(name) database is unavailable, so a complete backup could not be created."
        case .invalidPackage:
            "This is not a valid Up Next backup. No data was changed."
        case .unsupportedVersion(let version):
            "This Up Next backup uses an unsupported format version (\(version))."
        case .checksumMismatch(let name):
            "The \(name) file in this backup is incomplete or has changed. No data was changed."
        case .invalidDatabase(let name):
            "The \(name) database in this backup is damaged. No data was changed."
        case .sqlite:
            "The database could not be safely copied for this backup. No data was changed."
        }
    }
}

/// Helpers for creating a package and staging an imported one for a later,
/// startup-time restore. This service never replaces a live database.
enum RestorableLibraryBackupArchive {
    static let formatVersion = 1
    static let packageExtension = "upnextbackup"
    static let manifestFilename = "manifest.json"
    static let pendingRestoreDefaultsKey = "restoreBackup.pendingDirectory.v1"

    private static let databaseFilenames = ["SharedDatabase.sqlite", "UserState.sqlite"]

    struct Manifest: Codable, Sendable {
        struct File: Codable, Sendable {
            let name: String
            let byteCount: Int64
            let sha256: String
        }

        let formatVersion: Int
        let createdAt: Date
        let files: [File]
        let includes: [String]
        let excludes: [String]
    }

    struct StagedBackup: Sendable {
        let manifest: Manifest
        let directoryURL: URL

        var sharedDatabaseURL: URL { directoryURL.appendingPathComponent("SharedDatabase.sqlite") }
        var userStateDatabaseURL: URL { directoryURL.appendingPathComponent("UserState.sqlite") }
    }

    private struct RestoreSafetyManifest: Codable {
        let existingStoreFilenames: [String]
    }

    /// Creates a FileWrapper directory package with consistent SQLite snapshots.
    /// The caller should run this away from the main actor for larger libraries.
    static func create(sharedDatabaseURL: URL, userStateDatabaseURL: URL) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpNextBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for (source, name) in zip([sharedDatabaseURL, userStateDatabaseURL], databaseFilenames) {
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw RestorableLibraryBackupError.sourceUnavailable(name)
                }
                try makeSQLiteSnapshot(from: source, to: root.appendingPathComponent(name))
            }

            let files = try databaseFilenames.map { name -> Manifest.File in
                let url = root.appendingPathComponent(name)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                return Manifest.File(name: name, byteCount: byteCount, sha256: try checksum(at: url))
            }
            let manifest = Manifest(
                formatVersion: formatVersion,
                createdAt: .now,
                files: files,
                includes: [
                    "Subscriptions, podcasts and episode library data",
                    "Queue and playlist definitions and ordering",
                    "Playback progress, bookmarks and listening history",
                    "Local chapter edits and transcript data",
                    "Podcast and episode preferences stored in the databases"
                ],
                excludes: [
                    "Downloaded and imported media files",
                    "Private feed credentials stored in Keychain",
                    "App preferences stored outside the databases",
                    "Historical migration and recovery databases"
                ]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: root.appendingPathComponent(manifestFilename), options: .atomic)
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// Validates an imported package and copies its databases to an isolated
    /// staging directory. The caller applies this only before opening stores,
    /// after it has preserved a rollback copy of the current databases.
    static func validateAndStage(selectedPackageURL: URL, stagingParentURL: URL) throws -> StagedBackup {
        let packageURL = selectedPackageURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw RestorableLibraryBackupError.invalidPackage }

        let manifest = try readAndValidateManifest(at: packageURL)
        let stagingURL = stagingParentURL.appendingPathComponent("ValidatedBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        do {
            for file in manifest.files {
                let source = packageURL.appendingPathComponent(file.name)
                let destination = stagingURL.appendingPathComponent(file.name)
                try FileManager.default.copyItem(at: source, to: destination)
                try verify(file: file, at: destination)
                try checkDatabase(at: destination, expectedName: file.name)
            }
            return StagedBackup(manifest: manifest, directoryURL: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    static func scheduleRestore(_ backup: StagedBackup, defaults: UserDefaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard) {
        defaults.set(backup.directoryURL.path, forKey: pendingRestoreDefaultsKey)
    }

    /// Applies a validated restore before either SwiftData store opens. A
    /// rollback package remains in the App Group until the owner removes it.
    /// The pending path is cleared only after both stores have been replaced.
    static func applyPendingRestoreBeforeStoresOpen(
        sharedDatabaseURL: URL?,
        userStateDatabaseURL: URL?,
        appGroupURL: URL?,
        defaults: UserDefaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    ) throws -> Bool {
        guard let stagedPath = defaults.string(forKey: pendingRestoreDefaultsKey) else { return false }
        let selectedStagingURL = URL(fileURLWithPath: stagedPath)
        guard let sharedDatabaseURL, let userStateDatabaseURL, let appGroupURL else {
            throw RestorableLibraryBackupError.invalidPackage
        }
        let staged = try validateAndStage(
            selectedPackageURL: selectedStagingURL,
            stagingParentURL: FileManager.default.temporaryDirectory
        )
        defer { try? FileManager.default.removeItem(at: staged.directoryURL) }

        let libraryDirectory = appGroupURL.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let rollbackURL = libraryDirectory.appendingPathComponent(
            "RestoreSafety-\(UUID().uuidString).upnextbackup",
            isDirectory: true
        )
        try createRestoreSafetyCopy(
            sharedDatabaseURL: sharedDatabaseURL,
            userStateDatabaseURL: userStateDatabaseURL,
            destinationURL: rollbackURL
        )

        let replacements = [
            (staged.sharedDatabaseURL, sharedDatabaseURL),
            (staged.userStateDatabaseURL, userStateDatabaseURL)
        ]
        let incoming = replacements.map { (_, target) in
            target.deletingLastPathComponent()
                .appendingPathComponent(".\(target.lastPathComponent).restore-\(UUID().uuidString)")
        }
        do {
            for (index, replacement) in replacements.enumerated() {
                try FileManager.default.copyItem(at: replacement.0, to: incoming[index])
            }
            for (index, replacement) in replacements.enumerated() {
                try removeSQLiteArtifacts(for: replacement.1)
                try FileManager.default.moveItem(at: incoming[index], to: replacement.1)
            }
            defaults.removeObject(forKey: pendingRestoreDefaultsKey)
            try? FileManager.default.removeItem(at: selectedStagingURL)
            return true
        } catch {
            for url in incoming { try? FileManager.default.removeItem(at: url) }
            try? restoreRollback(rollbackURL, to: replacements.map(\.1))
            throw error
        }
    }

    private static func restoreRollback(_ packageURL: URL, to targets: [URL]) throws {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            let safetyManifestURL = packageURL.appendingPathComponent("restore-safety.json")
            let safetyManifest = try JSONDecoder().decode(
                RestoreSafetyManifest.self,
                from: Data(contentsOf: safetyManifestURL)
            )
            let existing = Set(safetyManifest.existingStoreFilenames)
            for (filename, target) in zip(databaseFilenames, targets) {
                try removeSQLiteArtifacts(for: target)
                guard existing.contains(filename) else { continue }
                let source = packageURL.appendingPathComponent(filename)
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    let sourceFile = URL(fileURLWithPath: source.path + suffix)
                    guard FileManager.default.fileExists(atPath: sourceFile.path) else { continue }
                    try FileManager.default.copyItem(
                        at: sourceFile,
                        to: URL(fileURLWithPath: target.path + suffix)
                    )
                }
            }
            return
        }
        let staged = try validateAndStage(
            selectedPackageURL: packageURL,
            stagingParentURL: FileManager.default.temporaryDirectory
        )
        defer { try? FileManager.default.removeItem(at: staged.directoryURL) }
        let sources = [staged.sharedDatabaseURL, staged.userStateDatabaseURL]
        for (source, target) in zip(sources, targets) {
            try removeSQLiteArtifacts(for: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    private static func createRestoreSafetyCopy(
        sharedDatabaseURL: URL,
        userStateDatabaseURL: URL,
        destinationURL: URL
    ) throws {
        if FileManager.default.fileExists(atPath: sharedDatabaseURL.path),
           FileManager.default.fileExists(atPath: userStateDatabaseURL.path) {
            let package = try create(
                sharedDatabaseURL: sharedDatabaseURL,
                userStateDatabaseURL: userStateDatabaseURL
            )
            try FileManager.default.moveItem(at: package, to: destinationURL)
            return
        }

        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        var existing: [String] = []
        for (source, filename) in zip([sharedDatabaseURL, userStateDatabaseURL], databaseFilenames)
        where FileManager.default.fileExists(atPath: source.path) {
            existing.append(filename)
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let sourceFile = URL(fileURLWithPath: source.path + suffix)
                guard FileManager.default.fileExists(atPath: sourceFile.path) else { continue }
                try FileManager.default.copyItem(
                    at: sourceFile,
                    to: destinationURL.appendingPathComponent(filename + suffix)
                )
            }
        }
        let manifest = RestoreSafetyManifest(existingStoreFilenames: existing)
        try JSONEncoder().encode(manifest).write(
            to: destinationURL.appendingPathComponent("restore-safety.json"),
            options: .atomic
        )
    }

    private static func removeSQLiteArtifacts(for storeURL: URL) throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    fileprivate static func validate(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isDirectory,
              let wrappers = fileWrapper.fileWrappers,
              let manifestWrapper = wrappers[manifestFilename],
              let manifestData = manifestWrapper.regularFileContents,
              let files = try? decodeManifest(manifestData) else {
            throw RestorableLibraryBackupError.invalidPackage
        }
        let databaseFiles = files.files
        guard Set(wrappers.keys) == Set(databaseFilenames + [manifestFilename]),
              databaseFiles.map(\.name).sorted() == databaseFilenames.sorted() else {
            throw RestorableLibraryBackupError.invalidPackage
        }
        for file in databaseFiles {
            guard let data = wrappers[file.name]?.regularFileContents else {
                throw RestorableLibraryBackupError.invalidPackage
            }
            guard Int64(data.count) == file.byteCount,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw RestorableLibraryBackupError.checksumMismatch(file.name)
            }
        }
    }

    private static func readAndValidateManifest(at packageURL: URL) throws -> Manifest {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw RestorableLibraryBackupError.invalidPackage }
        let manifest = try decodeManifest(Data(contentsOf: manifestURL))
        let expected = Set(databaseFilenames)
        guard manifest.files.count == expected.count,
              Set(manifest.files.map(\.name)) == expected,
              manifest.files.allSatisfy({ $0.name == URL(fileURLWithPath: $0.name).lastPathComponent && $0.byteCount > 0 && $0.sha256.count == 64 }) else {
            throw RestorableLibraryBackupError.invalidPackage
        }
        for file in manifest.files {
            try verify(file: file, at: packageURL.appendingPathComponent(file.name))
        }
        return manifest
    }

    private static func decodeManifest(_ data: Data) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: data)
        guard manifest.formatVersion == formatVersion else {
            throw RestorableLibraryBackupError.unsupportedVersion(manifest.formatVersion)
        }
        return manifest
    }

    private static func verify(file: Manifest.File, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RestorableLibraryBackupError.checksumMismatch(file.name)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard byteCount == file.byteCount, try checksum(at: url) == file.sha256 else {
            throw RestorableLibraryBackupError.checksumMismatch(file.name)
        }
    }

    private static func checksum(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func makeSQLiteSnapshot(from sourceURL: URL, to destinationURL: URL) throws {
        var source: OpaquePointer?
        let sourceResult = sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard sourceResult == SQLITE_OK, let source else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open source database"
            if let source { sqlite3_close(source) }
            throw RestorableLibraryBackupError.sqlite(message)
        }
        defer { sqlite3_close(source) }

        var destination: OpaquePointer?
        let destinationResult = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationResult == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "could not create backup database"
            if let destination { sqlite3_close(destination) }
            throw RestorableLibraryBackupError.sqlite(message)
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw RestorableLibraryBackupError.sqlite(String(cString: sqlite3_errmsg(destination)))
        }
        var result = sqlite3_backup_step(backup, -1)
        var attempts = 0
        while result == SQLITE_BUSY || result == SQLITE_LOCKED {
            guard attempts < 100 else { break }
            attempts += 1
            Thread.sleep(forTimeInterval: 0.01)
            result = sqlite3_backup_step(backup, -1)
        }
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw RestorableLibraryBackupError.sqlite(String(cString: sqlite3_errmsg(destination)))
        }
        try checkDatabase(at: destinationURL, expectedName: destinationURL.lastPathComponent)
    }

    private static func checkDatabase(at url: URL, expectedName: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw RestorableLibraryBackupError.invalidDatabase(expectedName)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RestorableLibraryBackupError.invalidDatabase(expectedName)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0), String(cString: value) == "ok" else {
            throw RestorableLibraryBackupError.invalidDatabase(expectedName)
        }
    }
}
