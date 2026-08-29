import Foundation

enum StoreSplitLegacyCleanupError: LocalizedError, Equatable {
    case gateNotSatisfied
    case unexpectedTarget

    var errorDescription: String? {
        switch self {
        case .gateNotSatisfied:
            "Legacy cleanup is blocked until verification, convergence, recovery, and grace-period gates all pass."
        case .unexpectedTarget:
            "Legacy cleanup refused an unexpected SQLite target."
        }
    }
}

struct StoreSplitLegacyCleanupResult: Equatable, Sendable {
    let removedFileNames: [String]
}

/// Deliberate, gated cleanup for the migration source. Migration never calls
/// this service. Release orchestration must first close the source container and
/// prove every `LegacyStoreCleanupGate` condition independently.
enum StoreSplitLegacyCleanupService {
    static func removeVerifiedLegacyStore(
        at targetURL: URL,
        expectedStoreURL: URL,
        gate: LegacyStoreCleanupGate
    ) throws -> StoreSplitLegacyCleanupResult {
        guard gate.isSafe else {
            throw StoreSplitLegacyCleanupError.gateNotSatisfied
        }
        let target = targetURL.standardizedFileURL
        let expected = expectedStoreURL.standardizedFileURL
        guard target == expected,
              target.lastPathComponent == "SharedDatabase.sqlite" else {
            throw StoreSplitLegacyCleanupError.unexpectedTarget
        }

        let artifacts = [
            target,
            URL(fileURLWithPath: target.path + "-wal"),
            URL(fileURLWithPath: target.path + "-shm")
        ]
        var removed: [String] = []
        for artifact in artifacts where FileManager.default.fileExists(atPath: artifact.path) {
            try FileManager.default.removeItem(at: artifact)
            removed.append(artifact.lastPathComponent)
        }
        return StoreSplitLegacyCleanupResult(removedFileNames: removed)
    }
}
