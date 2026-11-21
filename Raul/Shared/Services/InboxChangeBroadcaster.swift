import Foundation

/// Coalesces `.inboxDidChange` posts.
///
/// A bulk refresh writes new episodes feed by feed, and every one of them should
/// reach the inbox list as soon as it is saved instead of waiting for the whole
/// run to finish. Posting once per episode would rebuild the inbox list, the tab
/// badge and the CarPlay templates dozens of times in a row, so the first post of
/// a burst goes out immediately and the rest are collapsed into at most one post
/// per `minimumInterval`.
@MainActor
enum InboxChangeBroadcaster {
    /// Shortest gap between two posts. The leading post is never delayed.
    private static let minimumInterval: TimeInterval = 1.0

    private static var lastPostDate: Date?
    private static var hasScheduledTrailingPost = false

    /// Posts `.inboxDidChange` now, or folds this call into a single trailing
    /// post when the previous one is still inside the throttle window.
    static func notifyInboxDidChange() {
        guard let lastPostDate else {
            post()
            return
        }

        let elapsed = Date().timeIntervalSince(lastPostDate)
        guard elapsed < minimumInterval else {
            post()
            return
        }

        guard hasScheduledTrailingPost == false else { return }
        hasScheduledTrailingPost = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(minimumInterval - elapsed))
            hasScheduledTrailingPost = false
            post()
        }
    }

    private static func post() {
        lastPostDate = Date()
        NotificationCenter.default.post(name: .inboxDidChange, object: nil)
    }
}

/// Coalesces the expensive library-index invalidations caused by a bulk feed
/// import. The first completed feed is published immediately; subsequent
/// changes produce at most one trailing invalidation per interval so a long
/// Refresh All continues to expose updates instead of waiting for the run end.
@MainActor
enum PodcastFeedImportInvalidationBroadcaster {
    private static let minimumInterval: TimeInterval = 1.0
    private static var lastPostDate: Date?
    private static var hasScheduledTrailingPost = false
    private static var trailingPostGeneration = 0

    static func notify() {
        guard let lastPostDate else {
            post()
            return
        }

        let elapsed = Date().timeIntervalSince(lastPostDate)
        guard elapsed < minimumInterval else {
            trailingPostGeneration &+= 1
            hasScheduledTrailingPost = false
            post()
            return
        }

        guard hasScheduledTrailingPost == false else { return }
        hasScheduledTrailingPost = true
        trailingPostGeneration &+= 1
        let generation = trailingPostGeneration
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(minimumInterval - elapsed))
            } catch {
                return
            }
            guard generation == trailingPostGeneration else { return }
            hasScheduledTrailingPost = false
            post()
        }
    }

    private static func post() {
        lastPostDate = Date()
        NotificationCenter.default.post(name: .smartPlaylistEpisodeDataDidChange, object: nil)
        NotificationCenter.default.post(name: .spotlightLibraryDidChange, object: nil)
    }
}
