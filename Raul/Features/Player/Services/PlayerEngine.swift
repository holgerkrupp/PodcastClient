import Foundation
import AVFoundation

enum PlaybackInterruptionEvent {
    case began
    case ended
    
    case finished
    
    case pause
    case resume

     
}

actor PlayerEngine {
    let avPlayer = AVPlayer()
    private let session = AVAudioSession.sharedInstance()
    private var interruptionHandler: (@Sendable (PlaybackInterruptionEvent) -> Void)?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var boundaryTimeObserver: Any?
    private var periodicTimeObserver: Any?
    private var activePlaybackStreamID: UInt64 = 0


     init() {
        do{
            try session.setCategory(.playback, mode: .spokenAudio)
           
        }catch{
            // print("Audio session setup failed:", error)
        }
        
         Task {
             await self.addInterruptionObserver()
             await self.addRouteChangeObserver()
         }
        
      }
    func setInterruptionHandler(_ handler: @escaping @Sendable (PlaybackInterruptionEvent) -> Void) {
           interruptionHandler = handler
       }
    
    private  func addInterruptionObserver() {
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
    }
    private  func addRouteChangeObserver() {
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
                Task { await self.sendInterrupt(type: .began) }
            }
        }
    }
    
    func sendInterrupt(type: PlaybackInterruptionEvent){
        // print("sendInterrupt type: \(type)")
        switch type {
        case .began:
            deactiveSession()
            self.interruptionHandler?(.began)
        case .ended:
            activateSession()
            self.interruptionHandler?(.ended)
        case .pause:
                deactiveSession()
               self.interruptionHandler?(.pause)
        case .resume:
            activateSession()
            self.interruptionHandler?(.resume)
        case .finished:
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
        activateSession()
        avPlayer.play()
    }
    
    func setRate(_ newRate: Float) async {
        if newRate > 0 {
            activateSession()
            avPlayer.playImmediately(atRate: newRate)
        } else {
            avPlayer.pause()
        }
    }

    func pause() {
        avPlayer.pause()
     //   deactiveSession()
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
    
    private func deactiveSession()  {
        do{
            try session.setActive(false)
        }catch{
            // print(error)
        }
    }
    
    private func activateSession()  {
        do{
            try session.setActive(true)
        }catch{
            // print(error)
        }
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
