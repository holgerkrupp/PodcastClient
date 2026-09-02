import Foundation
import AVFoundation

enum PlaybackInterruptionEvent: Sendable {
    case began
    case ended
    case finished
    case pause
    case resume
    case activationFailed(String)
}

#if os(iOS)
/// Serializes `AVAudioSession` configuration off the main thread.
///
/// `setCategory` and `setActive` are synchronous IPC to the media server and
/// can block the caller for tens of milliseconds; AVFoundation warns about it
/// when they run on the main thread ("This method can lead to UI
/// unresponsiveness"). `AVAudioSession` is thread-safe, so the work just moves
/// to a dedicated queue.
///
/// The queue is serial on purpose so category configuration and activation
/// cannot land out of order. Playback only starts from the completion handler:
/// starting `AVPlayer` while activation is still queued can leave the player
/// advancing without an output route after an interruption.
private enum AudioSessionConfigurator {
    private static let queue = DispatchQueue(
        label: "de.holgerkrupp.upnext.audio-session",
        qos: .userInitiated
    )

    static func activateForPlayback(
        completion: @escaping @Sendable (String?) -> Void
    ) {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                // Reapply the category because media-services resets and some
                // interruption paths can discard the previous configuration.
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                completion(nil)
            } catch {
                completion(String(describing: error))
            }
        }
    }
}
#endif

@MainActor
final class PlayerEngine {
    let avPlayer = AVPlayer()
    private var interruptionHandler: (@Sendable (PlaybackInterruptionEvent) -> Void)?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var boundaryTimeObserver: Any?
    private var periodicTimeObserver: Any?
    private var activePlaybackStreamID: UInt64 = 0
    private var playbackRequestID: UInt64 = 0


     init() {
         avPlayer.automaticallyWaitsToMinimizeStalling = false

#if os(iOS)
         Task {
             await self.addInterruptionObserver()
             await self.addRouteChangeObserver()
         }
#endif
        
      }
    func setInterruptionHandler(_ handler: @escaping @Sendable (PlaybackInterruptionEvent) -> Void) {
           interruptionHandler = handler
       }
    
    private  func addInterruptionObserver() {
#if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                Task{
                    await self?.sendInterrupt(type: .began)
                }
            case .ended:
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        Task{
                            await self?.sendInterrupt(type: .resume)
                        }
                    }else{
                        Task{
                            await self?.sendInterrupt(type: .ended)
                        }
                    }
                }else{
                    Task{
                        await self?.sendInterrupt(type: .ended)
                    }
                }

            @unknown default:
                // print("interrupted: unknown type: \(type)")
                break
            }
        }
#endif
    }
    private  func addRouteChangeObserver() {
#if os(iOS)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
            
            if reason == .oldDeviceUnavailable {
                // Headphones unplugged, pause playback
                Task { await self.sendInterrupt(type: .pause) }
            }
        }
#endif
    }
    
    func sendInterrupt(type: PlaybackInterruptionEvent){
        // print("sendInterrupt type: \(type)")
        switch type {
        case .began:
            self.interruptionHandler?(.began)
        case .ended:
            self.interruptionHandler?(.ended)
        case .pause:
            self.interruptionHandler?(.pause)
        case .resume:
            self.interruptionHandler?(.resume)
        case .finished, .activationFailed:
            break
        }
    }
    
    


    func getRate() async -> Float {
        return avPlayer.rate
    }

    func replaceCurrentItem(with item: AVPlayerItem) {
        guard  avPlayer.currentItem != item else {
            return
        }
        invalidatePendingPlaybackRequests()
        removeBoundaryTimeObserver()
        removeEndObserver()
        avPlayer.replaceCurrentItem(with: item)
    }

    func setBoundaryTimeObserver(
        at times: [CMTime],
        handler: @escaping @Sendable () -> Void
    ) {
        removeBoundaryTimeObserver()
        guard times.isEmpty == false else { return }

        boundaryTimeObserver = avPlayer.addBoundaryTimeObserver(
            forTimes: times.map { NSValue(time: $0) },
            queue: .main
        ) {
            handler()
        }
    }

    func removeBoundaryTimeObserver() {
        if let boundaryTimeObserver {
            avPlayer.removeTimeObserver(boundaryTimeObserver)
            self.boundaryTimeObserver = nil
        }
    }
    


    func play() {
        resume(atRate: 1)
    }

    /// Starts session activation immediately, then begins playback only after
    /// iOS confirms that the session owns an output route.
    func resume(atRate rate: Float) {
        guard rate > 0 else {
            pause()
            return
        }

#if os(iOS)
        playbackRequestID &+= 1
        let requestID = playbackRequestID
        AudioSessionConfigurator.activateForPlayback { [weak self] failureDescription in
            Task { @MainActor [weak self] in
                guard let self, self.playbackRequestID == requestID else { return }
                guard let failureDescription else {
                    self.avPlayer.playImmediately(atRate: rate)
                    return
                }

                self.interruptionHandler?(.activationFailed(failureDescription))
            }
        }
#else
        avPlayer.playImmediately(atRate: rate)
#endif
    }

    func setRate(_ newRate: Float) async {
        resume(atRate: newRate)
    }

    func pause() {
        invalidatePendingPlaybackRequests()
        avPlayer.pause()
    }

    func seek(to time: CMTime) async {
        await withCheckedContinuation { continuation in
            avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }


    func isPlaying() -> Bool {
         return avPlayer.rate != 0
     }
    
    private func invalidatePendingPlaybackRequests() {
        playbackRequestID &+= 1
    }

    func currentTime() -> Double {
        avPlayer.currentTime().seconds
    }

    func currentItemDuration() -> Double? {
        let duration = avPlayer.currentItem?.duration.seconds
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func removeEndObserver(for streamID: UInt64) {
        guard streamID == activePlaybackStreamID else { return }
        removeEndObserver()
    }

    private func removePeriodicTimeObserver() {
        if let periodicTimeObserver {
            avPlayer.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }
    }

    private func removePlaybackStreamObservers(for streamID: UInt64) {
        guard streamID == activePlaybackStreamID else { return }
        removeEndObserver()
        removePeriodicTimeObserver()
    }
    
    func playbackStream(interval: TimeInterval = 1.0) -> AsyncStream<PlaybackEvent> {
        let currentItem = avPlayer.currentItem
        activePlaybackStreamID &+= 1
        let streamID = activePlaybackStreamID
        removeEndObserver()
        removePeriodicTimeObserver()
        let safeInterval = max(interval, 0.25)

        return AsyncStream<PlaybackEvent> { continuation in
            let observer = avPlayer.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: safeInterval, preferredTimescale: 600),
                queue: .main
            ) { time in
                continuation.yield(.position(time.seconds))
            }
            self.periodicTimeObserver = observer

            let endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main
            ) { [weak self] _ in
                continuation.yield(.ended)
                continuation.finish()
                Task{
                    await self?.sendInterrupt(type: .finished)
                }
            }
            self.endObserver = endObserver

            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removePlaybackStreamObservers(for: streamID)
                }
            }
        }
    }
    
}

enum PlaybackEvent {
    case position(Double)
    case ended
}
