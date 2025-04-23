import Foundation
import AVFoundation

actor PlayerEngine {
    private var avPlayer = AVPlayer()
    private var endObserver: Any?
    private var playbackEndedContinuation: AsyncStream<Double>.Continuation?
    private let session = AVAudioSession.sharedInstance()

    init() {
        avPlayer = AVPlayer()
        do{
            try session.setCategory(.playback, mode: .spokenAudio)
        }catch{
            print(error)
        }
      }
    
    func setRate(_ newRate: Float) async {
        avPlayer.rate = newRate
    }

    func getRate() async -> Float {
        return avPlayer.rate
    }

    func replaceCurrentItem(with item: AVPlayerItem) {
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
            Task { await self?.handlePlaybackEnded() }
        }
    }

    private func handlePlaybackEnded() {
        playbackEndedContinuation?.finish()
        playbackEndedContinuation = nil
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

    
    func playbackPositionStream(interval: TimeInterval = 0.5) -> AsyncStream<Double> {
        AsyncStream { continuation in
            Task {
                while !Task.isCancelled {
                    let position = avPlayer.currentTime().seconds
                    continuation.yield(position)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                // You could handle any cleanup if needed here
            }
        }
    }
}
