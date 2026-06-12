import Foundation

enum ShareExtensionError: LocalizedError {
    case missingExtensionContext
    case noURL
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .missingExtensionContext:
            return "The shared item could not be accessed."
        case .noURL:
            return "No URL was shared."
        case .appGroupUnavailable:
            return "The shared episode could not be saved."
        }
    }
}
