import Foundation
import Testing
import UIKit
@testable import UpNext

@Suite("Playback system pressure")
struct PlaybackSystemPressureTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func snapshot(
        at seconds: TimeInterval,
        position: Double,
        isPlaying: Bool = true,
        episode: String = "episode",
        rate: Double = 1
    ) -> WidgetPlaybackSnapshot {
        WidgetPlaybackSnapshot(
            updatedAt: start.addingTimeInterval(seconds),
            episodeID: episode,
            isPlaying: isPlaying,
            positionSeconds: position,
            durationSeconds: 3600,
            playbackRate: rate,
            title: "Title",
            podcastTitle: "Podcast",
            coverFileName: nil,
            backgroundFileName: nil,
            skipBackSymbol: nil,
            skipForwardSymbol: nil,
            skipBackSeconds: 15,
            skipForwardSeconds: 30
        )
    }

    @Test func gradualProgressNeverReloadsTheQueueAndNowPlayingOnlyEveryFiveMinutes() {
        var lastReload: Date? = start
        var previous = snapshot(at: 0, position: 0)
        var nowPlayingReloads = 0
        for minute in 1...30 {
            let next = snapshot(at: Double(minute * 60), position: Double(minute * 60))
            let decision = WidgetPlaybackReloadPolicy.decision(previous: previous, next: next, lastNowPlayingReloadAt: lastReload)
            #expect(decision.reloadQueue == false)
            if decision.reloadNowPlaying {
                nowPlayingReloads += 1
                lastReload = next.updatedAt
            }
            previous = next
        }
        #expect(nowPlayingReloads == 6)
    }

    @Test func meaningfulChangesReloadImmediately() {
        let previous = snapshot(at: 0, position: 100)
        let justReloaded = start

        let paused = WidgetPlaybackReloadPolicy.decision(
            previous: previous, next: snapshot(at: 5, position: 105, isPlaying: false), lastNowPlayingReloadAt: justReloaded
        )
        #expect(paused == .init(reloadNowPlaying: true, reloadQueue: true))

        let newEpisode = WidgetPlaybackReloadPolicy.decision(
            previous: previous, next: snapshot(at: 5, position: 0, episode: "other"), lastNowPlayingReloadAt: justReloaded
        )
        #expect(newEpisode == .init(reloadNowPlaying: true, reloadQueue: true))

        let seek = WidgetPlaybackReloadPolicy.decision(
            previous: previous, next: snapshot(at: 5, position: 900), lastNowPlayingReloadAt: justReloaded
        )
        #expect(seek == .init(reloadNowPlaying: true, reloadQueue: false))

        let faster = WidgetPlaybackReloadPolicy.decision(
            previous: previous, next: snapshot(at: 5, position: 105, rate: 1.5), lastNowPlayingReloadAt: justReloaded
        )
        #expect(faster.reloadNowPlaying)
    }

    @Test func nowPlayingArtworkIsBoundedAndSmallImagesPassThrough() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let large = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        }
        let bounded = try #require(NowPlayingInfoActor.boundedArtworkImage(large))
        let cgImage = try #require(bounded.cgImage)
        #expect(cgImage.width == 1024)
        #expect(cgImage.height == 512)
        #expect(bounded.scale == 1)

        let small = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: format).image { _ in }
        #expect(NowPlayingInfoActor.boundedArtworkImage(small) === small)

        #expect(NowPlayingInfoActor.boundedArtworkImage(UIImage()) == nil)
    }
}
