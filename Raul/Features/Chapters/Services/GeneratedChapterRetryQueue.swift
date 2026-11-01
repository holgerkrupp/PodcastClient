import Foundation

enum GeneratedChapterRetryReason: Sendable, Equatable {
    /// The model was busy, rate limited or still preparing its assets.
    case transient
    /// A background window ended before the pass finished.
    case cancelled
}

/// Episodes whose automatic chapter pass stopped for a reason that will clear.
///
/// A finished transcript means the episode is no longer a transcription candidate,
/// so nothing else would ever try its chapters again. Background apps hit the
/// model's rate limit often enough for that to matter. Kept in UserDefaults because
/// it is small and losing it only loses the retry.
actor GeneratedChapterRetryQueue {
    static let shared = GeneratedChapterRetryQueue()

    static let maximumAttempts = 5
    static let maximumEntries = 32
    static let baseBackoff: TimeInterval = 30 * 60
    static let cancelledBackoff: TimeInterval = 10 * 60
    private static let storageKey = "GeneratedChapterRetryQueue.v1"

    private struct Entry: Codable {
        var attempts: Int
        var notBefore: Date
    }

    private let defaults: UserDefaults
    private var entries: [URL: Entry]
    private var dismissed: Set<URL> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([URL: Entry].self, from: $0) } ?? [:]
    }

    func enqueue(_ episodeURL: URL, reason: GeneratedChapterRetryReason, now: Date = Date()) {
        if dismissed.remove(episodeURL) != nil {
            remove(episodeURL)
            return
        }
        var entry = entries[episodeURL] ?? Entry(attempts: 0, notBefore: now)
        switch reason {
        case .cancelled:
            entry.notBefore = now.addingTimeInterval(Self.cancelledBackoff)
        case .transient:
            entry.attempts += 1
            guard entry.attempts < Self.maximumAttempts else {
                AppDiagnostics.log("generated_chapter_retry_gave_up attempts=\(entry.attempts)")
                remove(episodeURL)
                return
            }
            entry.notBefore = now.addingTimeInterval(
                Self.baseBackoff * pow(2, Double(entry.attempts - 1))
            )
        }
        entries[episodeURL] = entry
        if entries.count > Self.maximumEntries,
           let latest = entries.max(by: { $0.value.notBefore < $1.value.notBefore })?.key {
            entries.removeValue(forKey: latest)
        }
        persist()
    }

    func nextDue(now: Date = Date(), excluding excluded: Set<URL> = []) -> URL? {
        entries
            .filter { $0.value.notBefore <= now && excluded.contains($0.key) == false }
            .min { $0.value.notBefore < $1.value.notBefore }?
            .key
    }

    func remove(_ episodeURL: URL) {
        guard entries.removeValue(forKey: episodeURL) != nil else { return }
        persist()
    }

    /// The user cancelled, so a pass that is still winding down must not requeue itself.
    func dismiss(_ episodeURL: URL) {
        dismissed.insert(episodeURL)
        remove(episodeURL)
    }

    /// A new pass was requested, so an older dismissal no longer applies.
    func clearDismissal(_ episodeURL: URL) {
        dismissed.remove(episodeURL)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
