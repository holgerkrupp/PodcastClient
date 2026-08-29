import Combine
import Foundation
import SwiftData

/// Snapshot of a "refresh all podcasts" run, as the UI needs to draw it.
struct PodcastRefreshProgress: Sendable, Equatable {
    var isRefreshing: Bool = false
    var completed: Int = 0
    var total: Int = 0
    var lastFetchDate: Date?
    var errorMessage: String?

    static let idle = PodcastRefreshProgress()
}

/// Shared state of a user-initiated "refresh all podcasts" run.
///
/// The library and the inbox both offer a refresh button, and both used to own a
/// private view model. A refresh started in the library therefore left the inbox
/// looking idle even though feeds were being fetched. Both screens now observe
/// this one coordinator, so whichever screen starts the run, every screen shows
/// the same progress and the same disabled button.
///
/// The coordinator itself has no actor isolation: feed workers report progress
/// from whatever executor they happen to run on, and a lock keeps the snapshot
/// consistent. Announcements reach the UI through ``progressPublisher``, which
/// hops to the main queue for its subscribers, so the refresh never has to hop
/// to the main actor just to record a number.
final class PodcastRefreshCoordinator: @unchecked Sendable {
    static let shared = PodcastRefreshCoordinator()

    private let lock = NSLock()
    private let subject = CurrentValueSubject<PodcastRefreshProgress, Never>(.idle)
    private var activeRefresh: Task<Void, Never>?

    /// Announces every change to the snapshot, on the main queue.
    ///
    /// Stored rather than computed: a fresh `AnyPublisher` per body evaluation
    /// makes SwiftUI tear the subscription down and build it up again on every
    /// redraw.
    let progressPublisher: AnyPublisher<PodcastRefreshProgress, Never>

    private init() {
        progressPublisher = subject
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// The latest snapshot, for a view that needs a value before its first
    /// publisher delivery.
    var progress: PodcastRefreshProgress {
        subject.value
    }

    /// Refreshes every subscribed feed, or joins the run that is already going so
    /// a second screen waits for the same work instead of starting a duplicate pass.
    func refreshAllPodcasts(modelContainer: ModelContainer) async {
        await startOrJoinRefresh(modelContainer: modelContainer).value
    }

    /// Synchronous so the whole decision — join or start, and announce the start —
    /// happens in one critical section. `NSLock` is off limits in an async context.
    private func startOrJoinRefresh(modelContainer: ModelContainer) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }

        if let activeRefresh {
            return activeRefresh
        }

        var started = subject.value
        started.isRefreshing = true
        started.completed = 0
        started.total = 0
        started.errorMessage = nil

        let task = Task {
            await self.performRefresh(modelContainer: modelContainer)
        }
        activeRefresh = task
        // Announced inside the lock so the "started" snapshot can never land after
        // a progress update from the task it started.
        subject.send(started)
        return task
    }

    private func performRefresh(modelContainer: ModelContainer) async {
        var errorMessage: String?

        do {
            let actor = PodcastModelActor(modelContainer: modelContainer)
            try await actor.refreshAllPodcasts { [weak self] completed, total in
                self?.report(completed: completed, total: total)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        finish(errorMessage: errorMessage)
    }

    private func report(completed: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }

        var snapshot = subject.value
        guard snapshot.isRefreshing else { return }
        snapshot.completed = completed
        snapshot.total = total
        subject.send(snapshot)
    }

    private func finish(errorMessage: String?) {
        lock.lock()
        defer { lock.unlock() }

        activeRefresh = nil

        var snapshot = subject.value
        snapshot.isRefreshing = false
        snapshot.errorMessage = errorMessage
        if errorMessage == nil {
            snapshot.lastFetchDate = Date()
        }
        subject.send(snapshot)
    }
}
