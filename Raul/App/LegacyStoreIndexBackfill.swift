import Foundation
import SQLite3

/// Creates the models' `#Index` entries on a legacy store that already exists.
///
/// SwiftData only materialises `#Index` when it *creates* a store. A fetch index
/// is not part of CoreData's entity version hash, so adding one to a model does
/// not trigger a migration, and opening an existing store applies nothing —
/// verified by writing a store with the previous build and reopening it with
/// this one: the rows survived untouched and no index appeared. Existing
/// installs are exactly the ones paying for the missing indexes (unindexed
/// `ORDER BY` with a growing `fetchOffset` makes SQLite spill a temp B-tree to
/// disk on every migration slice), so the statements are issued directly.
///
/// The names and definitions are exactly what SwiftData emits for the same
/// `#Index` declarations, so a backfilled store is indistinguishable from a
/// freshly created one and `IF NOT EXISTS` keeps this a no-op on both.
enum LegacyStoreIndexBackfill {
    private struct Index {
        let name: String
        let table: String
        let columns: [String]

        var createStatement: String {
            let columnList = columns
                .map { "\($0) COLLATE BINARY ASC" }
                .joined(separator: ", ")
            return "CREATE INDEX IF NOT EXISTS \(name) ON \(table) (\(columnList))"
        }
    }

    private static let indexes = [
        Index(
            name: "Z_Episode_SwiftDataIndexOnBinarypublishDate",
            table: "ZEPISODE",
            columns: ["ZPUBLISHDATE"]
        ),
        Index(
            name: "Z_Episode_SwiftDataIndexOnBinarypodcastpublishDate",
            table: "ZEPISODE",
            columns: ["ZPODCAST", "ZPUBLISHDATE"]
        ),
        Index(
            name: "Z_PlaySession_SwiftDataIndexOnBinarystartTime",
            table: "ZPLAYSESSION",
            columns: ["ZSTARTTIME"]
        ),
        Index(
            name: "Z_PlaylistEntry_SwiftDataIndexOnBinaryorder",
            table: "ZPLAYLISTENTRY",
            columns: ["ZORDER"]
        )
    ]

    /// Best effort, and deliberately silent on failure: a store that is missing,
    /// still locked by another app-group process, or not yet created keeps
    /// whatever indexes it has and is retried on the next launch. The container
    /// open must never depend on this.
    static func run(storeURL: URL) {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return
        }
        defer { sqlite3_close(handle) }

        // The widget and the share extension open the same store. Wait briefly
        // for a write lock rather than giving up on the first contended launch.
        sqlite3_busy_timeout(handle, 2_000)

        let missing = indexes.filter { existingIndexNames(handle).contains($0.name) == false }
        guard missing.isEmpty == false else { return }

        let started = Date()
        var created: [String] = []
        for index in missing {
            // A table that does not exist yet is expected on a store the models
            // have never written to, and is not worth reporting.
            guard tableExists(handle, name: index.table) else { continue }
            guard sqlite3_exec(handle, index.createStatement, nil, nil, nil) == SQLITE_OK else {
                CrashBreadcrumbs.shared.record(
                    "legacy_store_index_backfill_failed",
                    details: "\(index.name):\(lastErrorMessage(handle))"
                )
                continue
            }
            created.append(index.name)
        }

        guard created.isEmpty == false else { return }
        CrashBreadcrumbs.shared.record(
            "legacy_store_index_backfill_completed",
            details: "created=\(created.count),seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))"
        )
    }

    private static func existingIndexNames(_ handle: OpaquePointer) -> Set<String> {
        var names: Set<String> = []
        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'index'"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            return names
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) {
                names.insert(String(cString: raw))
            }
        }
        return names
    }

    private static func tableExists(_ handle: OpaquePointer, name: String) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: the bound string must be copied, it does not outlive
        // this call.
        sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func lastErrorMessage(_ handle: OpaquePointer) -> String {
        guard let raw = sqlite3_errmsg(handle) else { return "unknown" }
        return String(cString: raw)
    }
}
