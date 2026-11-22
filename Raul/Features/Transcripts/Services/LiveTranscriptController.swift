import AVFoundation
import Foundation
import Observation
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@ModelActor
actor LiveTranscriptStoreActor {
    func load(episodeURL: URL) throws -> LiveTranscriptState? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.url == episodeURL })
        descriptor.fetchLimit = 1
        guard let data = try modelContext.fetch(descriptor).first?.liveTranscriptData else { return nil }
        return try JSONDecoder().decode(LiveTranscriptState.self, from: data)
    }

    func append(episodeURL: URL, fingerprint: String, windows: [LiveTranscriptState.FinalWindow]) throws -> Bool {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.url == episodeURL })
        descriptor.fetchLimit = 1
        guard let episode = try modelContext.fetch(descriptor).first else { return false }
        var state: LiveTranscriptState
        if let data = episode.liveTranscriptData {
            state = try JSONDecoder().decode(LiveTranscriptState.self, from: data)
            guard state.mediaFingerprint == fingerprint else { return false }
        } else {
            state = LiveTranscriptState(mediaFingerprint: fingerprint)
        }
        for window in windows { state.append(cues: window.cues, coverage: window.coverage) }
        episode.liveTranscriptData = try JSONEncoder().encode(state)
        try modelContext.save()
        episode.refresh.toggle()
        return true
    }
}

/// A user-started, bounded local-file transcription session. The player keeps
/// running; recognition and disk writes happen outside the audio callback.
@MainActor
@Observable
final class LiveTranscriptController {
    static let shared = LiveTranscriptController()

    enum Phase: Equatable { case idle, preparing, catchingUp, following, unavailable }
    enum UnavailableReason: Equatable {
        case notDownloaded
        case playbackMediaMismatch
        case fullTranscriptionInProgress
        case unsupportedLocale
        case speechModelUnavailable
        case invalidAudioFormat
        case mediaChanged
        case analysisFailed

        var message: String {
            switch self {
            case .notDownloaded:
                "Download this episode to transcribe as you listen."
            case .playbackMediaMismatch:
                "Playback is still using the streamed version. Restart from the downloaded copy to transcribe live."
            case .fullTranscriptionInProgress:
                "Full transcription is already in progress for this episode."
            case .unsupportedLocale:
                "Live transcription is not available for this episode language on this device."
            case .speechModelUnavailable:
                "The speech model is unavailable. Check the language model download and try again."
            case .invalidAudioFormat:
                "This downloaded media format cannot be transcribed."
            case .mediaChanged:
                "The downloaded media changed during transcription. Try again."
            case .analysisFailed:
                "Live transcription could not analyze this media. Try again."
            }
        }
    }
    private(set) var phase: Phase = .idle
    private(set) var unavailableReason: UnavailableReason?
    private(set) var episodeURL: URL?
    private(set) var cues: [LiveTranscriptState.Cue] = []
    private(set) var tentativeCues: [LiveTranscriptState.Cue] = []
    private(set) var coverage: [LiveTranscriptState.Coverage] = []
    private(set) var pendingSaveEpisodeURL: URL?

    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var drainingWorker: Task<Void, Never>?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var observedPlayer: AVPlayer?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lastTime: TimeInterval?
    @ObservationIgnored private var mediaURL: URL?
    @ObservationIgnored private var language: String?
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var fingerprint: String?
    @ObservationIgnored private var fingerprintSignature: FileSignature?
    @ObservationIgnored private var store: LiveTranscriptStoreActor?
    @ObservationIgnored private var storeContainerID: ObjectIdentifier?
    @ObservationIgnored private var cachedLines: [UUID: (LiveTranscriptState.Cue, TranscriptLineAndTime)] = [:]
    @ObservationIgnored private var cachedStateData: Data?
    @ObservationIgnored private var cachedState: LiveTranscriptState?
    private struct PendingSave {
        let store: LiveTranscriptStoreActor
        let episodeURL: URL
        let fingerprint: String
        let windows: [LiveTranscriptState.FinalWindow]
    }
    private struct FileSignature: Equatable {
        let size: Int
        let modified: Date
    }
    @ObservationIgnored private var pendingSaves: [PendingSave] = []
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?

    private init() {
#if canImport(UIKit)
        let notification = UIApplication.willEnterForegroundNotification
#elseif canImport(AppKit)
        let notification = NSApplication.didBecomeActiveNotification
#else
        return
#endif
        foregroundObserver = NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.retryPendingSaves() }
        }
    }

    func isActive(for episode: Episode) -> Bool {
        episode.url != nil && episode.url == episodeURL && phase != .idle && phase != .unavailable
    }

    func displayLines(for episode: Episode) -> [TranscriptLineAndTime] {
        if let full = episode.transcriptLines, !full.isEmpty { return full }
        let saved: LiveTranscriptState?
        if isActive(for: episode) {
            saved = nil
        } else if episode.liveTranscriptData == cachedStateData {
            saved = cachedState
        } else {
            cachedStateData = episode.liveTranscriptData
            cachedState = episode.liveTranscriptData.flatMap { try? JSONDecoder().decode(LiveTranscriptState.self, from: $0) }
            saved = cachedState
        }
        let visible: [LiveTranscriptState.Cue]
        if isActive(for: episode) {
            visible = (cues + tentativeCues).sorted { $0.start < $1.start }
        } else {
            let pending = pendingSaves.filter { $0.episodeURL == episode.url }
                .flatMap(\.windows).flatMap(\.cues)
            var byID: [UUID: LiveTranscriptState.Cue] = [:]
            for cue in saved?.cues ?? [] { byID[cue.id] = cue }
            for cue in pending { byID[cue.id] = cue }
            visible = byID.values.sorted { $0.start < $1.start }
        }
        if cachedLines.count > visible.count * 2 + 100 {
            let activeIDs = Set(visible.map(\.id))
            cachedLines = cachedLines.filter { activeIDs.contains($0.key) }
        }
        return visible.map { cue in
            if let cached = cachedLines[cue.id], cached.0 == cue { return cached.1 }
            let line = TranscriptLineAndTime(id: cue.id, text: cue.text, startTime: cue.start, endTime: cue.end,
                                             source: .localAI, timedSpans: cue.spans,
                                             generatedMediaFingerprint: saved?.mediaFingerprint ?? fingerprint)
            cachedLines[cue.id] = (cue, line)
            return line
        }
    }

    func start(episode: Episode, container: ModelContainer) async {
        retryPendingSaves()
        guard let episodeURL = episode.url else {
            unavailableReason = .notDownloaded
            phase = .unavailable
            return
        }
        guard let media = episode.localFile,
              FileManager.default.fileExists(atPath: media.path) else {
            self.episodeURL = episodeURL
            unavailableReason = .notDownloaded
            phase = .unavailable
            return
        }
        if EpisodeAIGenerationCoordinator.shared.isRunning(for: episodeURL) {
            self.episodeURL = episodeURL
            unavailableReason = .fullTranscriptionInProgress
            phase = .unavailable
            return
        }
        stop()
        // A download can finish while the player is still using its streamed
        // item. Reuse the player's state-preserving replacement path so timed
        // captions always match the media the listener hears.
        await Player.shared.switchCurrentEpisodeToDownloadedCopyIfNeeded()
        guard Player.shared.isPlayingLocalTranscriptMedia(episodeURL: episodeURL, localMediaURL: media) else {
            self.episodeURL = episodeURL
            unavailableReason = .playbackMediaMismatch
            phase = .unavailable
            return
        }
        self.episodeURL = episodeURL
        self.mediaURL = media
        self.language = episode.podcast?.language
        self.container = container
        if store == nil || storeContainerID != ObjectIdentifier(container) {
            store = LiveTranscriptStoreActor(modelContainer: container)
            storeContainerID = ObjectIdentifier(container)
        }
        phase = .preparing
        unavailableReason = nil
        let player = Player.shared.videoPlayer
        observedPlayer = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.playbackChanged(time.seconds) }
        }
        if !Player.shared.isPlaying { Player.shared.play() }
        restart()
    }

    func stop() {
        generation = UUID()
        drainingWorker = worker ?? drainingWorker
        worker?.cancel()
        worker = nil
        if let observer, let observedPlayer { observedPlayer.removeTimeObserver(observer) }
        observer = nil
        observedPlayer = nil
        episodeURL = nil
        unavailableReason = nil
        mediaURL = nil
        container = nil
        fingerprint = nil
        fingerprintSignature = nil
        lastTime = nil
        cues = []
        tentativeCues = []
        coverage = []
        cachedLines.removeAll()
        phase = .idle
    }

    func stopAndWait() async {
        let previous = worker ?? drainingWorker
        stop()
        await previous?.value
        drainingWorker = nil
    }

    func discardPendingSaves(for episodeURL: URL?) async {
        let runningRetry = retryTask
        runningRetry?.cancel()
        await runningRetry?.value
        if let episodeURL { pendingSaves.removeAll { $0.episodeURL == episodeURL } }
        else { pendingSaves.removeAll() }
        pendingSaveEpisodeURL = pendingSaves.first?.episodeURL
        retryPendingSaves()
    }

    private func playbackChanged(_ time: TimeInterval) {
        guard phase != .idle, phase != .unavailable else { return }
        guard let episodeURL, let mediaURL,
              Player.shared.isPlayingLocalTranscriptMedia(episodeURL: episodeURL, localMediaURL: mediaURL),
              observedPlayer === Player.shared.videoPlayer else {
            markUnavailable(token: generation, reason: .playbackMediaMismatch)
            return
        }
        guard time.isFinite else { return }
        if let lastTime, abs(time - lastTime) > 4 {
            restart()
        }
        lastTime = time
    }

    private func restart() {
        let previous = worker ?? drainingWorker
        previous?.cancel()
        drainingWorker = nil
        tentativeCues = []
        let token = UUID()
        generation = token
        worker = Task {
            await previous?.value
            guard !Task.isCancelled, generation == token else { return }
            await run(token: token)
        }
    }

    private func markUnavailable(token: UUID, reason: UnavailableReason = .analysisFailed) {
        guard generation == token else { return }
        if let observer, let observedPlayer { observedPlayer.removeTimeObserver(observer) }
        observer = nil
        observedPlayer = nil
        unavailableReason = reason
        phase = .unavailable
    }

    func retryPendingSaves() {
        guard retryTask == nil, !pendingSaves.isEmpty else { return }
        retryTask = Task { @MainActor in
            defer { retryTask = nil }
            for delay in [0, 5, 15] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { break }
                guard let first = pendingSaves.first else { break }
                do {
                    if try await first.store.append(episodeURL: first.episodeURL, fingerprint: first.fingerprint, windows: first.windows) {
                        pendingSaves.removeFirst()
                        pendingSaveEpisodeURL = pendingSaves.first?.episodeURL
                        if !pendingSaves.isEmpty { continue }
                        break
                    }
                } catch {
                    AppDiagnostics.log("live_transcript_retry_failed phase=retry pending=\(pendingSaves.count)")
                }
            }
        }
    }

    private func enqueueRetry(store: LiveTranscriptStoreActor, episodeURL: URL,
                              fingerprint: String, windows: [LiveTranscriptState.FinalWindow]) {
        guard !windows.isEmpty else { return }
        pendingSaves.append(PendingSave(store: store, episodeURL: episodeURL, fingerprint: fingerprint, windows: windows))
        pendingSaveEpisodeURL = pendingSaves.first?.episodeURL
        retryPendingSaves()
    }

    private func run(token: UUID) async {
        guard let episodeURL, let mediaURL, let container, let store else { return }
        let actor = EpisodeActor(modelContainer: container)
        var pending: [LiveTranscriptState.FinalWindow] = []
        var sessionFingerprint: String?
        do {
            let initialSignature: FileSignature
            do {
                initialSignature = try Self.fileSignature(mediaURL)
                _ = try AVAudioFile(forReading: mediaURL)
            } catch {
                markUnavailable(token: token, reason: .invalidAudioFormat)
                return
            }
            let mediaFingerprint: String
            if let fingerprint, fingerprintSignature == initialSignature { mediaFingerprint = fingerprint } else {
                let hashTask = Task.detached(priority: .utility) { try TranscriptMediaFingerprint.make(for: mediaURL) }
                mediaFingerprint = try await withTaskCancellationHandler { try await hashTask.value } onCancel: { hashTask.cancel() }
                try Task.checkCancellation()
                guard generation == token else { return }
                fingerprint = mediaFingerprint
                fingerprintSignature = initialSignature
            }
            guard try Self.fileSignature(mediaURL) == initialSignature else {
                markUnavailable(token: token, reason: .mediaChanged)
                return
            }
            sessionFingerprint = mediaFingerprint
            let saved = try await store.load(episodeURL: episodeURL)
            guard saved == nil || saved?.mediaFingerprint == mediaFingerprint else {
                markUnavailable(token: token, reason: .mediaChanged)
                return
            }
            var state = saved ?? LiveTranscriptState(mediaFingerprint: mediaFingerprint)
            cues = state.cues
            coverage = state.coverage
            let isVideo = Player.shared.currentPlaybackIsVideo
            let duration: TimeInterval
            if isVideo {
                duration = try await AVURLAsset(url: mediaURL).load(.duration).seconds
            } else {
                duration = try await Task.detached(priority: .utility) { try TranscriptAudioSampler.duration(of: mediaURL) }.value
            }
            guard duration.isFinite, duration > 0 else { throw TranscriptAudioSnippetError.invalidFormat }
            let initialTime = Player.shared.videoPlayer.currentTime().seconds
            var cursor = initialTime.isFinite ? max(0, floor(initialTime / 7) * 7) : 0
            while !Task.isCancelled && generation == token {
                guard Player.shared.isPlayingLocalTranscriptMedia(episodeURL: episodeURL, localMediaURL: mediaURL) else {
                    markUnavailable(token: token, reason: .playbackMediaMismatch)
                    break
                }
                guard try Self.fileSignature(mediaURL) == initialSignature else {
                    markUnavailable(token: token, reason: .mediaChanged)
                    break
                }
                if pendingSaveEpisodeURL == episodeURL {
                    retryPendingSaves()
                    try await Task.sleep(for: .seconds(5))
                    continue
                }
                if await actor.hasTranscript(for: episodeURL) {
                    if generation == token { stop() }
                    break
                }
                let playhead = Player.shared.videoPlayer.currentTime().seconds
                guard playhead.isFinite else { try await Task.sleep(for: .milliseconds(300)); continue }
                if !Player.shared.isPlaying { try await Task.sleep(for: .milliseconds(300)); continue }
                if cursor < playhead - 14 { cursor = max(0, floor(playhead / 7) * 7) }
                if cursor > playhead + 14 || cursor >= duration {
                    phase = .following
                    try await Task.sleep(for: .milliseconds(400))
                    continue
                }
                if let covered = state.coverage.first(where: { cursor >= $0.start && cursor < $0.end - 0.01 }) {
                    cursor = covered.end
                    continue
                }
                phase = .catchingUp
                let center = min(cursor + 3.5, max(0, duration - 3.5))
                let snippet: TranscriptAudioSampler.Snippet
                if isVideo {
                    snippet = try await Self.extractVideoAudioWindow(mediaURL: mediaURL, start: max(0, center - min(7, duration) / 2), duration: min(7, duration))
                } else {
                    snippet = try await Task.detached(priority: .utility) {
                        try TranscriptAudioSampler.writeSnippet(from: mediaURL, centeredAt: center, duration: min(7, duration))
                    }.value
                }
                defer { try? FileManager.default.removeItem(at: snippet.url.deletingLastPathComponent()) }
                let snippetStart = snippet.startTime
                guard let results = try await TranscriptionManager.shared.transcribeClip(audioURL: snippet.url, language: language, tentativeHandler: { [weak self] result in
                    await self?.updateTentative(result, offset: snippetStart, token: token)
                }, usesTimeCodedInput: true) else {
                    let supported = await AITranscripts.supportedSpeechLocale(for: language) != nil
                    markUnavailable(token: token, reason: supported ? .speechModelUnavailable : .unsupportedLocale)
                    break
                }
                try Task.checkCancellation()
                guard generation == token else { break }
                guard try Self.fileSignature(mediaURL) == initialSignature else {
                    markUnavailable(token: token, reason: .mediaChanged)
                    break
                }
                let end = min(duration, snippet.startTime + 7)
                let finalCues = results.compactMap { result -> LiveTranscriptState.Cue? in
                    let start = snippet.startTime + result.range.start.seconds
                    let finish = snippet.startTime + result.range.end.seconds
                    guard start.isFinite, finish.isFinite, finish > start, !result.text.isEmpty,
                          start >= snippet.startTime - 0.05, finish <= end + 0.15 else { return nil }
                    return LiveTranscriptState.Cue(id: UUID(), text: result.text, start: start, end: finish,
                        spans: result.timedSpans.map {
                            TranscriptTimedSpan(location: $0.location, length: $0.length,
                                startTime: snippet.startTime + $0.startTime, endTime: snippet.startTime + $0.endTime,
                                cueLevel: $0.cueLevel)
                        })
                }
                guard finalCues.count == results.count else {
                    markUnavailable(token: token, reason: .analysisFailed)
                    break
                }
                let window = LiveTranscriptState.FinalWindow(coverage: .init(start: snippet.startTime, end: end), cues: finalCues)
                tentativeCues.removeAll { $0.start < end && $0.end > snippet.startTime }
                state.append(cues: finalCues, coverage: window.coverage)
                pending.append(window)
                cues = state.cues
                coverage = state.coverage
                cursor = end
                if pending.count >= 3 {
                    do {
                        guard try await store.append(episodeURL: episodeURL, fingerprint: mediaFingerprint, windows: pending) else { break }
                        pending.removeAll()
                    } catch {
                        enqueueRetry(store: store, episodeURL: episodeURL, fingerprint: mediaFingerprint, windows: pending)
                        pending.removeAll()
                    }
                }
            }
        } catch is CancellationError {
        } catch is TranscriptAudioSnippetError {
            markUnavailable(token: token, reason: .invalidAudioFormat)
        } catch {
            markUnavailable(token: token, reason: .analysisFailed)
        }
        if !pending.isEmpty, let sessionFingerprint {
            do {
                if try await store.append(episodeURL: episodeURL, fingerprint: sessionFingerprint, windows: pending) == false {
                    enqueueRetry(store: store, episodeURL: episodeURL, fingerprint: sessionFingerprint, windows: pending)
                }
            } catch {
                AppDiagnostics.log("live_transcript_save_failed phase=finalize pending=\(pending.count)")
                enqueueRetry(store: store, episodeURL: episodeURL, fingerprint: sessionFingerprint, windows: pending)
            }
        }
    }

    private static func fileSignature(_ url: URL) throws -> FileSignature {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let modified = values.contentModificationDate else {
            throw TranscriptAudioSnippetError.invalidFormat
        }
        return FileSignature(size: size, modified: modified)
    }

    static func extractVideoAudioWindow(mediaURL: URL, start: TimeInterval, duration: TimeInterval) async throws -> TranscriptAudioSampler.Snippet {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("window.m4a")
        do {
            guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: mediaURL), presetName: AVAssetExportPresetAppleM4A) else {
                throw TranscriptAudioSnippetError.invalidFormat
            }
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                             duration: CMTime(seconds: duration, preferredTimescale: 600))
            try await exporter.export(to: output, as: .m4a)
            return TranscriptAudioSampler.Snippet(url: output, startTime: start)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func updateTentative(_ result: AITranscripts.TimedResult, offset: TimeInterval, token: UUID) {
        guard generation == token else { return }
        let start = offset + result.range.start.seconds
        let end = offset + result.range.end.seconds
        guard start.isFinite, end.isFinite, end > start, !result.text.isEmpty else { return }
        let overlapping = tentativeCues.first { $0.start < end && $0.end > start }
        let cue = LiveTranscriptState.Cue(id: overlapping?.id ?? UUID(), text: result.text, start: start, end: end,
            spans: result.timedSpans.map {
                TranscriptTimedSpan(location: $0.location, length: $0.length,
                    startTime: offset + $0.startTime, endTime: offset + $0.endTime, cueLevel: $0.cueLevel)
            })
        tentativeCues.removeAll { $0.start < end && $0.end > start }
        tentativeCues.append(cue)
    }
}
