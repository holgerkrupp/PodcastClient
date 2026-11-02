import Foundation
import os

/// Privacy-safe context for CarPlay freezes and reconnects: states, counts and
/// durations only, never titles, URLs or artwork. The last command and playback
/// change live in memory and are written as breadcrumbs only at connection
/// transitions, so remote commands never cause disk writes.
@MainActor
enum CarPlayDiagnostics {
    nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UpNext", category: "CarPlayScene")

    private static var lastCommand: (name: String, at: Date)?
    private static var lastPlaybackChange: (isPlaying: Bool, at: Date)?

    static func noteCommand(_ name: StaticString) {
        lastCommand = ("\(name)", .now)
        logger.debug("Remote command \(name, privacy: .public)")
    }

    static func notePlaybackStateChange(isPlaying: Bool) {
        lastPlaybackChange = (isPlaying, .now)
    }

    /// Records a connection transition together with the recent command and
    /// playback context.
    static func recordTransition(_ event: String, details: String? = nil) {
        let summary = [details, contextSummary()].compactMap { $0 }.joined(separator: " ")
        logger.info("\(event, privacy: .public) \(summary, privacy: .public)")
        CrashBreadcrumbs.shared.record(event, details: summary)
    }

    static func contextSummary(now: Date = .now) -> String {
        let command = lastCommand.map { "lastCommand=\($0.name) commandAgeS=\(Int(now.timeIntervalSince($0.at)))" }
            ?? "lastCommand=none"
        let playback = lastPlaybackChange.map {
            "playing=\($0.isPlaying) playbackChangeAgeS=\(Int(now.timeIntervalSince($0.at)))"
        } ?? "playbackChange=none"
        return "\(command) \(playback)"
    }
}
