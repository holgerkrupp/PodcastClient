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
    private var avPlayer = AVPlayer()
    private var endObserver: Any?
    private var playbackEndedContinuation: AsyncStream<Void>.Continuation?
    private let session = AVAudioSession.sharedInstance()
    private var interruptionHandler: (@Sendable (PlaybackInterruptionEvent) -> Void)?


     init() {
        avPlayer = AVPlayer()
        do{
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        }catch{
            print("Audio session setup failed:", error)
        }
        
         Task {
             await self.addEndObserver()
             await self.addChangeObserver()
         }
        
      }
    func setInterruptionHandler(_ handler: @escaping @Sendable (PlaybackInterruptionEvent) -> Void) {
           interruptionHandler = handler
       }
    
    private  func addEndObserver() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
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
                print("interrupted: unknown type: \(type)")
                break
            }
        }
    }
    private  func addChangeObserver() {
        NotificationCenter.default.addObserver(
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
        print("sendInterrupt type: \(type)")
        switch type {
        case .began:
            try? self.session.setActive(false)
            self.interruptionHandler?(.began)
        case .ended:
            break
        case .pause:
            //   self.avPlayer.pause()
               try? self.session.setActive(false)
               self.interruptionHandler?(.pause)
        case .resume:
            try? self.session.setActive(true)
            self.interruptionHandler?(.resume)
        case .finished:
            break
        }
    }
    
    
    func setRate(_ newRate: Float) async {
        avPlayer.rate = newRate
    }

    func getRate() async -> Float {
        return avPlayer.rate
    }

    func replaceCurrentItem(with item: AVPlayerItem) {
        guard  avPlayer.currentItem != item else {
            return
        }
        avPlayer.replaceCurrentItem(with: item)

        // Remove any previous observer
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        try? session.setActive(true)
        // Observe end of playback
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task {
            }
        }
    }
    


    func play() {
        do{
            try session.setActive(true)
        }catch{
            print(error)

        }
            avPlayer.play()
    }

    func pause() {
        avPlayer.pause()
    }
    
    func setRate(_ rate: Float) {
        avPlayer.rate = rate
    }

    func seek(to time: CMTime) {
        avPlayer.seek(to: time)
    }


    func isPlaying() -> Bool {
         return avPlayer.rate != 0
     }

    
    func playbackStream(interval: TimeInterval = 0.5) -> AsyncStream<PlaybackEvent> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let position = avPlayer.currentTime().seconds
                    continuation.yield(.position(position))
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }

            let endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { _ in
                continuation.yield(.ended)
                continuation.finish()
                task.cancel()
                Task{
                    await self.sendInterrupt(type: .finished)
                }
            }

            continuation.onTermination = { _ in
           //     NotificationCenter.default.removeObserver(endObserver)
                task.cancel()
            }
        }
    }
    
}

enum PlaybackEvent {
    case position(Double)
    case ended
}
