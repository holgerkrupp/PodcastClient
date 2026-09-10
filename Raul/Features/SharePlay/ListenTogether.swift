//
//  ListenTogether.swift
//  Up Next
//
//  SharePlay: listen to an episode together. The AVPlayer's playback
//  coordinator keeps play, pause, seeking and speed in sync for everyone;
//  this file makes sure every participant has the same episode loaded.
//

import AVFoundation
import BasicLogger
import CoreTransferable
import Foundation
import GroupActivities
import Observation
import Synchronization
import SwiftUI

// MARK: - Activity

struct ListenTogetherActivity: GroupActivity {
    static let activityIdentifier = "de.holgerkrupp.PodcastClient.listen-together"

    /// The episode's enclosure URL, which every participant's library keys
    /// the episode by.
    let episodeURL: URL
    /// Lets a participant who doesn't follow the podcast import the episode.
    let feedURL: URL?
    let pageURL: URL?
    let title: String
    let podcastTitle: String?

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.type = .listenTogether
        metadata.title = title
        metadata.subtitle = podcastTitle
        metadata.fallbackURL = pageURL ?? episodeURL
        return metadata
    }

    init?(episode: Episode) {
        guard let url = episode.url else { return nil }
        episodeURL = url
        feedURL = episode.podcast?.feed
        pageURL = episode.link
        title = episode.title
        podcastTitle = episode.podcast?.title
    }
}

/// Lets a ShareLink offer SharePlay in the share sheet, both during a
/// FaceTime call and to start one.
struct ListenTogetherInvitation: Transferable {
    let activity: ListenTogetherActivity

    static var transferRepresentation: some TransferRepresentation {
        GroupActivityTransferRepresentation { invitation in
            invitation.activity
        }
    }
}

// MARK: - Session

/// Tells the coordinator which episode the current item is. Without it the
/// coordinator compares asset URLs, so someone playing a downloaded copy and
/// someone streaming would count as playing different things.
private final class ListenTogetherCoordinatorDelegate: NSObject, AVPlayerPlaybackCoordinatorDelegate, Sendable {
    private let currentEpisodeIdentifier = Mutex<String?>(nil)

    func setCurrentEpisodeURL(_ url: URL?) {
        currentEpisodeIdentifier.withLock { $0 = url?.absoluteString }
    }

    func playbackCoordinator(
        _ coordinator: AVPlayerPlaybackCoordinator,
        identifierFor playerItem: AVPlayerItem
    ) -> String {
        currentEpisodeIdentifier.withLock { $0 }
            ?? (playerItem.asset as? AVURLAsset)?.url.absoluteString
            ?? ""
    }
}

@MainActor
@Observable
final class ListenTogetherController {
    static let shared = ListenTogetherController()

    private(set) var isInSession = false

    @ObservationIgnored private var session: GroupSession<ListenTogetherActivity>?
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private let coordinatorDelegate = ListenTogetherCoordinatorDelegate()

    private init() {}

    /// Starts receiving sessions. Call at launch: accepting an invitation can
    /// launch the app, and the session is only delivered through this sequence.
    func startListening() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            for await session in ListenTogetherActivity.sessions() {
                self?.configure(session)
            }
        }
    }

    func leave() {
        session?.leave()
    }

    private func configure(_ newSession: GroupSession<ListenTogetherActivity>) {
        session?.leave()
        endSession()

        session = newSession
        isInSession = true

        let player = Player.shared
        player.isInSharedListeningSession = true
        coordinatorDelegate.setCurrentEpisodeURL(player.currentEpisodeURL)
        let avPlayer = player.videoPlayer
        avPlayer.playbackCoordinator.delegate = coordinatorDelegate
        avPlayer.playbackCoordinator.coordinateWithSession(newSession)

        sessionTasks = [
            Task { [weak self] in
                for await state in newSession.$state.values {
                    if case .invalidated = state {
                        self?.sessionDidEnd(newSession)
                        return
                    }
                }
            },
            Task { [weak self] in
                for await activity in newSession.$activity.values {
                    await self?.loadEpisode(for: activity)
                }
            },
            Task { [weak self] in
                // When this participant switches episodes, the group follows.
                for await episodeURL in Observations({ Player.shared.currentEpisodeURL }) {
                    self?.localEpisodeDidChange(to: episodeURL)
                }
            }
        ]

        newSession.join()
    }

    private func loadEpisode(for activity: ListenTogetherActivity) async {
        guard Player.shared.currentEpisodeURL != activity.episodeURL else { return }
        do {
            let episodeURL = try await episodeURLInLibrary(for: activity)
            // Load without playing: the coordinator starts playback in step
            // with the group.
            await Player.shared.playEpisode(episodeURL, playDirectly: false, skipProtectionBehavior: .ignore)
        } catch {
            BasicLogger.shared.log("SharePlay: could not load \(activity.episodeURL.absoluteString): \(error.localizedDescription)")
        }
    }

    private func episodeURLInLibrary(for activity: ListenTogetherActivity) async throws -> URL {
        if await Player.shared.fetchEpisode(with: activity.episodeURL) != nil {
            return activity.episodeURL
        }
        return try await PodcastEpisodeShareImporter().importEpisode(
            episodeURL: activity.episodeURL,
            feedURL: activity.feedURL,
            modelContext: ModelContainerManager.shared.container.mainContext
        )
    }

    private func localEpisodeDidChange(to episodeURL: URL?) {
        coordinatorDelegate.setCurrentEpisodeURL(episodeURL)
        guard let session,
              let episodeURL,
              episodeURL != session.activity.episodeURL,
              let episode = Player.shared.currentEpisode,
              let activity = ListenTogetherActivity(episode: episode) else {
            return
        }
        session.activity = activity
    }

    private func sessionDidEnd(_ endedSession: GroupSession<ListenTogetherActivity>) {
        guard endedSession === session else { return }
        endSession()
    }

    private func endSession() {
        sessionTasks.forEach { $0.cancel() }
        sessionTasks = []
        session = nil
        guard isInSession else { return }
        isInSession = false
        Player.shared.isInSharedListeningSession = false
        Player.shared.videoPlayer.playbackCoordinator.delegate = nil
    }
}

// MARK: - UI

/// Starts SharePlay for the episode, or leaves the current session.
struct ListenTogetherButton: View {
    let episode: Episode

    var body: some View {
        if ListenTogetherController.shared.isInSession {
            Button {
                ListenTogetherController.shared.leave()
            } label: {
                Label("Leave SharePlay", systemImage: "shareplay.slash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass(.clear))
            .accessibilityHint("Stops listening together")
        } else if let activity = ListenTogetherActivity(episode: episode) {
            ShareLink(
                item: ListenTogetherInvitation(activity: activity),
                preview: SharePreview(episode.title)
            ) {
                Label("Listen Together", systemImage: "shareplay")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass(.clear))
            .accessibilityHint("Listen to this episode with others using SharePlay")
        }
    }
}
