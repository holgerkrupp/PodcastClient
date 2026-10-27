import CryptoKit
import Foundation
import Observation
import SwiftUI
import TipKit

/// A draft is local to this device. Only a rule explicitly saved in podcast
/// settings becomes part of the synchronised PodcastSettings model.
struct ChapterSkipRuleSuggestion: Codable, Hashable, Sendable {
    let podcastKey: String
    let keyword: String
    let skipCount: Int
}

/// A small, bounded, Codable state machine so skip counting can be tested
/// without a player, model container, or TipKit datastore.
struct ChapterSkipRecognitionHistory: Codable {
    struct Keyword: Codable {
        var episodeKeys: Set<String> = []
        var lastSeen: Date
        var wasSuggested = false
    }

    var keywordsByPodcast: [String: [String: Keyword]] = [:]
    var pendingByPodcast: [String: ChapterSkipRuleSuggestion] = [:]

    static let minimumEpisodes = 5
    private static let preferredWords: Set<String> = [
        "werbung", "anzeige", "sponsor", "sponsored", "sponsorenhinweis",
        "advertisement", "advertising", "promo", "promotion", "ads", "ad",
        "intro", "outro", "credits", "vorspann", "abspann"
    ]
    private static let ignoredWords: Set<String> = [
        "the", "and", "for", "with", "from", "about", "this", "that", "your",
        "chapter", "chapters", "episode", "part", "section", "segment", "podcast",
        "die", "der", "das", "den", "dem", "des", "ein", "eine", "einer", "einem",
        "und", "mit", "von", "für", "zum", "zur", "über", "folge", "kapitel",
        "teil", "abschnitt", "minute", "minuten", "uhr", "today", "heute",
        "next", "previous", "start", "end", "ende", "beginning", "introductory"
    ]

    static func keywords(in title: String) -> Set<String> {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(words.compactMap { word -> String? in
            let token = String(word)
            guard (token.count >= 3 || preferredWords.contains(token)), token.count <= 40,
                  token.unicodeScalars.contains(where: CharacterSet.letters.contains),
                  ignoredWords.contains(token) == false else { return nil }
            return token
        })
    }

    /// Each episode contributes at most one observation per word, regardless
    /// of the number of chapters or manual controls used on that episode.
    mutating func record(
        podcastKey: String,
        episodeKey: String,
        title: String,
        now: Date = Date()
    ) -> ChapterSkipRuleSuggestion? {
        guard podcastKey.isEmpty == false, episodeKey.isEmpty == false else { return nil }
        let tokens = Self.keywords(in: title)
        guard tokens.isEmpty == false else { return nil }
        defer { prune() }

        let expiry = now.addingTimeInterval(-180 * 24 * 60 * 60)
        var podcastKeywords = keywordsByPodcast[podcastKey] ?? [:]
        podcastKeywords = podcastKeywords.filter { $0.value.lastSeen >= expiry }

        var newlyQualified: [String] = []
        for token in tokens {
            var keyword = podcastKeywords[token] ?? Keyword(lastSeen: now)
            let inserted = keyword.episodeKeys.insert(episodeKey).inserted
            keyword.lastSeen = now
            if inserted && keyword.episodeKeys.count >= Self.minimumEpisodes && !keyword.wasSuggested {
                newlyQualified.append(token)
            }
            // Stop growing a successful counter without losing deduplication
            // for the small number of episodes retained.
            if keyword.episodeKeys.count > 32 {
                keyword.episodeKeys = Set(keyword.episodeKeys.sorted().prefix(32))
            }
            podcastKeywords[token] = keyword
        }
        keywordsByPodcast[podcastKey] = podcastKeywords

        // Never replace a tip that the listener has not acted on yet.
        guard pendingByPodcast[podcastKey] == nil,
              let chosen = newlyQualified.sorted(by: { lhs, rhs in
                  let leftPreferred = Self.preferredWords.contains(lhs)
                  let rightPreferred = Self.preferredWords.contains(rhs)
                  if leftPreferred != rightPreferred { return leftPreferred }
                  if lhs.count != rhs.count { return lhs.count > rhs.count }
                  return lhs < rhs
              }).first else { return nil }
        var keyword = podcastKeywords[chosen]!
        keyword.wasSuggested = true
        podcastKeywords[chosen] = keyword
        keywordsByPodcast[podcastKey] = podcastKeywords
        let suggestion = ChapterSkipRuleSuggestion(
            podcastKey: podcastKey,
            keyword: chosen,
            skipCount: keyword.episodeKeys.count
        )
        pendingByPodcast[podcastKey] = suggestion
        return suggestion
    }

    mutating func complete(_ suggestion: ChapterSkipRuleSuggestion) {
        if pendingByPodcast[suggestion.podcastKey] == suggestion {
            pendingByPodcast.removeValue(forKey: suggestion.podcastKey)
        }
    }

    mutating func dismiss(_ suggestion: ChapterSkipRuleSuggestion) {
        complete(suggestion)
    }

    private mutating func prune() {
        // Keep local history modest even for listeners with many subscriptions.
        if keywordsByPodcast.count > 64 {
            let ordered = keywordsByPodcast.keys.sorted {
                (keywordsByPodcast[$0]?.values.map(\.lastSeen).max() ?? .distantPast)
                    < (keywordsByPodcast[$1]?.values.map(\.lastSeen).max() ?? .distantPast)
            }
            for key in ordered.prefix(keywordsByPodcast.count - 64) {
                keywordsByPodcast.removeValue(forKey: key)
                pendingByPodcast.removeValue(forKey: key)
            }
        }
        for key in keywordsByPodcast.keys {
            guard var words = keywordsByPodcast[key], words.count > 60 else { continue }
            let oldest = words.keys.sorted {
                (words[$0]?.lastSeen ?? .distantPast) < (words[$1]?.lastSeen ?? .distantPast)
            }
            for token in oldest.prefix(words.count - 60) {
                words.removeValue(forKey: token)
            }
            keywordsByPodcast[key] = words
        }
    }
}

@MainActor
@Observable
final class ChapterSkipRecognition {
    static let shared = ChapterSkipRecognition()
    private static let storageKey = "ChapterSkipRecognition.localHistory.v1"

    private(set) var history: ChapterSkipRecognitionHistory
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(ChapterSkipRecognitionHistory.self, from: $0) }
            ?? ChapterSkipRecognitionHistory()
    }

    static func podcastKey(for feed: URL) -> String {
        digest(feed.absoluteString)
    }

    static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func suggestion(for feed: URL?) -> ChapterSkipRuleSuggestion? {
        guard let feed else { return nil }
        return history.pendingByPodcast[Self.podcastKey(for: feed)]
    }

    func recordManuallySkippedChapter(_ chapter: Marker) {
        guard chapter.shouldPlay,
              chapter.type != .transcriptGap,
              chapter.type != .bookmark,
              chapter.type != .soundbite,
              let episode = chapter.episode,
              let feed = episode.podcast?.feed,
              let episodeURL = episode.url else { return }

        _ = history.record(
            podcastKey: Self.podcastKey(for: feed),
            episodeKey: Self.digest(episodeURL.absoluteString),
            title: chapter.displayTitle
        )
        persist()
    }

    /// Don't interpret reaching the natural end of a chapter as a preference
    /// to skip that type of content.
    static func isDeliberateNextChapterSkip(
        position: TimeInterval,
        chapterStart: TimeInterval,
        chapterEnd: TimeInterval
    ) -> Bool {
        let duration = chapterEnd - chapterStart
        let remaining = chapterEnd - position
        return duration > 0 && position >= chapterStart && position < chapterEnd
            && remaining >= max(10, duration * 0.15)
    }

    func complete(_ suggestion: ChapterSkipRuleSuggestion) {
        history.complete(suggestion)
        persist()
    }

    func dismiss(_ suggestion: ChapterSkipRuleSuggestion) {
        history.dismiss(suggestion)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        // Standard defaults are local (not NSUbiquitousKeyValueStore and not
        // part of either CloudKit-backed SwiftData schema).
        defaults.set(data, forKey: Self.storageKey)
    }
}

struct ChapterSkipSuggestionTip: Tip {
    let suggestion: ChapterSkipRuleSuggestion

    var id: String {
        "chapter-skip-suggestion.\(suggestion.podcastKey).\(suggestion.keyword)"
    }

    var title: Text { Text("Skip this chapter automatically?") }
    var message: Text? {
        Text("You've skipped chapters containing “\(suggestion.keyword)” in \(suggestion.skipCount) episodes. Create a rule for this podcast?")
    }
    var image: Image? { Image(systemName: "forward.end.circle.fill") }
    var actions: [Action] {
        [
            Action(id: "create-rule", title: "Review Skip Rule"),
            Action(id: "not-now", title: "Not Now")
        ]
    }
    var options: [TipOption] {
        [Tips.IgnoresDisplayFrequency(true), MaxDisplayCount(3)]
    }
}
