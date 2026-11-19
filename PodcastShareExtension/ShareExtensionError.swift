import Foundation

enum ShareExtensionError: LocalizedError {
    case missingExtensionContext
    case noURL
    case appGroupUnavailable
    case resetInProgress

    var errorDescription: String? {
        switch self {
        case .missingExtensionContext:
            return "The shared item could not be accessed."
        case .noURL:
            return "No URL was shared."
        case .appGroupUnavailable:
            return "The shared episode could not be saved."
        case .resetInProgress:
            return "Up Next is clearing its data. Try sharing this item again after the reset finishes."
        }
    }
}
