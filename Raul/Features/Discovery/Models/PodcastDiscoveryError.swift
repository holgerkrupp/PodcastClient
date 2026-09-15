//
//  PodcastDiscoveryError.swift
//  Raul
//
//  Typed provider errors. The messages stay deliberately generic: endpoints,
//  HTML selectors and status codes must never reach the user.
//

import Foundation

enum PodcastDiscoveryError: LocalizedError, Sendable, Equatable {
    /// The provider does not offer this browse mode at all.
    case unsupportedOperation
    /// The service could not be reached, or answered with an error status.
    case unavailable
    /// A response arrived but was not of the expected kind.
    case invalidResponse
    /// The response could not be interpreted (JSON/HTML shape changed).
    case parsingFailed
    /// No RSS feed could be found for this show.
    case feedNotFound
    /// The provider needs configuration (an API key) that has not been supplied.
    case configurationMissing

    var errorDescription: String? {
        switch self {
        case .unsupportedOperation:
            return String(localized: "This broadcaster does not offer that.")
        case .unavailable, .invalidResponse, .parsingFailed:
            return String(localized: "Currently unavailable. Try again later.")
        case .feedNotFound:
            return String(localized: "Feed unavailable")
        case .configurationMissing:
            return String(localized: "This broadcaster is not available in this build.")
        }
    }
}
