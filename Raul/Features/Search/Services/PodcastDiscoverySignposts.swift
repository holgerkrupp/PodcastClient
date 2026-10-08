import Foundation
import os

enum PodcastDiscoverySignposts {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "PodcastClient",
        category: .pointsOfInterest
    )

    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, id: OSSignpostID, count: Int = -1) {
        os_signpost(.end, log: log, name: name, signpostID: id, "count=%{public}d", count)
    }
}
