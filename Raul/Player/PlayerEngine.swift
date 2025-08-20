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
           
        }catch{
            // print("Audio session setup failed:", error)
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
                // print("interrupted: unknown type: \(type)")
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
        // print("sendInterrupt type: \(type)")
        switch type {
        case .began:
            deactiveSession()
            self.interruptionHandler?(.began)
        case .ended:
            break
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
        avPlayer.replaceCurrentItem(with: item)

        // Remove any previous observer
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }

        /*
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task {
            }
        }
        */
    }
    


    func play() {
        activateSession()
        avPlayer.play()
    }
    
    func setRate(_ newRate: Float) async {
        activateSession()
        avPlayer.rate = newRate
    }

    func pause() {
        avPlayer.pause()
        deactiveSession()
    }

    func seek(to time: CMTime) {
        avPlayer.seek(to: time)
    }


    func isPlaying() -> Bool {
         return avPlayer.rate != 0
     }
    
    private func deactiveSession()  {
        print ("deactiveSession called")
        do{
            try session.setActive(false)
        }catch{
            // print(error)
        }
    }
    
    private func activateSession()  {
        print ("activateSession called")
        
        do{
            try session.setActive(true)
        }catch{
            // print(error)
        }
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

            NotificationCenter.default.addObserver(
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
