import Foundation

enum StoreSplitMergePolicy {
    static func prefersIncoming(existingUpdatedAt: Date?, incomingUpdatedAt: Date?) -> Bool {
        switch (existingUpdatedAt, incomingUpdatedAt) {
        case (nil, nil):
            return false
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (existing?, incoming?):
            return incoming > existing
        }
    }
}
