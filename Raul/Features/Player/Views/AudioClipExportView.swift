import SwiftUI
import AVFoundation
import AVKit

struct AudioClipExportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 60
    @State private var isExporting = false
    @State private var showShareSheet = false
    @State private var exportURL: URL?
    @State private var coverImage: UIImage?
    @State private var waveformSamples: [Float] = []
    @State private var audioPlayer: AVAudioPlayer?
    @State private var videoPlayer: AVPlayer?
    @State private var playbackProgress: Double = 0
    @State private var audioDelegate: AudioPlayerDelegateWrapper?
    @State private var showPreviewUnavailableAlert = false
    @State private var exportProgress: Double = 0.0
    @State private var videoSize = CGSize(width: 720, height: 720)
    @State private var previewImage: UIImage?
    var title: String? = nil

    let audioURL: URL // The audio file URL to trim
    var isVideo: Bool = false
    let coverImageURL: URL? // The primary image URL to use as video background
    let fallbackCoverImageURL: URL? // The fallback image URL if primary fails
    let playPosition: Double // The center position for +/- 30s
    let duration: Double // Audio duration

    private var trimRange: ClosedRange<Double> {
        let minTime = max(0, playPosition - 30)
        let maxTime = min(duration, playPosition + 30)
        return minTime...maxTime
    }
    

    var body: some View {
        GeometryReader { geometry in
            ZStack{
                
                CoverImageView(episode: Player.shared.currentEpisode)
                    .aspectRatio(1, contentMode: .fill)
                    .scaledToFill()
                    .ignoresSafeArea(.all, edges: .bottom)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .blur(radius: 50)
                
                Group{
                    Spacer()
                    VStack(spacing: 16) {
                        
                        if isVideo == false {
                            VideoSizePicker(videoSize: $videoSize)
                        }
                        
                        Group {
                            if isVideo, let videoPlayer {
                                VideoClipPreviewPlayerView(player: videoPlayer)
                                    .aspectRatio(contentMode: .fit)
                                    .background(Color.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            } else if let previewImage {
                                Image(uiImage: previewImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                 //   .cornerRadius(16)
                                    .padding()
                            }  else {
                                ZStack {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.3))
                                        .cornerRadius(16)
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .accent))
                                }
                            }
                        }
                        .frame(
                            width: previewWidth(for: geometry.size),
                            height: previewHeight(for: geometry.size)
                        )
                        .onChange(of: coverImage) { updatePreviewImage() }
                        .onChange(of: trimStart) { updatePreviewImage() }
                        .onChange(of: trimEnd) { updatePreviewImage() }
                        .onChange(of: videoSize) {  updatePreviewImage() }
                        .onChange(of: playbackProgress) {  updatePreviewImage() }
                        
                        
                        Text("Select the segment to share")
                            .font(.headline)
                            .padding(.horizontal)
                        
                        if waveformSamples.isEmpty {
                            ZStack {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(height: 70)
                                    .cornerRadius(8)
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .accent))
                            }
                            .padding(.vertical)
                        } else {
                            VStack(spacing: 6) {
                                WaveformView(
                                    samples: waveformSamples.map { max($0, 0.05) },
                                    trimRange: trimRange,
                                    duration: duration,
                                    trimStart: trimStart,
                                    trimEnd: trimEnd,
                                    onTrimStartChanged: { newStart in
                                        trimStart = newStart
                                        if trimStart > trimEnd { trimStart = trimEnd }
                                        stopAudioPlayer()
                                    },
                                    onTrimEndChanged: { newEnd in
                                        trimEnd = newEnd
                                        if trimEnd < trimStart { trimEnd = trimStart }
                                        stopAudioPlayer()
                                    }, progress: $playbackProgress
                                )
                                .frame(height: 70)
                                .animation(reduceMotion ? nil : .easeInOut, value: waveformSamples)
                                .background{
                                    RoundedRectangle(cornerRadius:  8.0)
                                        .fill(.black.opacity(0.5))
                                }

                                    
                                    
                                    Button {
                                        togglePreview()
                                    } label: {
                                        Label(
                                            isPreviewPlaying ? "Pause" : "Preview",
                                            systemImage: isPreviewPlaying ? "pause.fill" : "play.fill"
                                        )
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.glass(.clear))
                                
                            }
                            .padding(.vertical)
                        }
                        
                        HStack {
                            Text("Start: \(formatTime(trimStart))")
                            Spacer()
                            Text("End: \(formatTime(trimEnd))")
                        }
                        .font(.caption)
                        .padding(.horizontal)
                        
                        HStack {
                            Button("Cancel") {
                                stopAudioPlayer()
                                dismiss()
                            }
                            .buttonStyle(.glass(.clear))
                            Spacer()
                            Button("Export") {
                                exportClip()
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(isExporting)
                        }
                        .padding(.horizontal)
                    }
                    .padding()
                   
                }
                
                
                .frame(width: geometry.size.width, height: geometry.size.height)
                .ignoresSafeArea(.all, edges: .bottom)
                
                .sheet(isPresented: $showShareSheet, onDismiss: {
                    stopAudioPlayer()
                    dismiss() 
                }) {
                    if let exportURL {
                        ShareSheet(activityItems: [exportURL])
                    }
                }
                .alert("Preview unavailable", isPresented: $showPreviewUnavailableAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Preview is only available for downloaded media files.")
                }
                .onAppear {
                    Player.shared.pause()
                    trimStart = trimRange.lowerBound
                    trimEnd = trimRange.upperBound
                    Task {
                        if let url = coverImageURL {
                            if let loaded = await ImageLoaderAndCache.loadUIImage(from: url) {
                                self.coverImage = loaded
                            } else if let fallbackURL = fallbackCoverImageURL, let fallbackLoaded = await ImageLoaderAndCache.loadUIImage(from: fallbackURL) {
                                self.coverImage = fallbackLoaded
                            } else {
                                self.coverImage = UIImage()
                            }
                        } else if let fallbackURL = fallbackCoverImageURL, let fallbackLoaded = await ImageLoaderAndCache.loadUIImage(from: fallbackURL) {
                            self.coverImage = fallbackLoaded
                        } else {
                            self.coverImage = UIImage()
                        }
                        waveformSamples = await WaveformView.extractSamples(from: audioURL, in: trimRange)
                        if waveformSamples.allSatisfy({ $0 < 0.07 }) {
                            waveformSamples = Array(repeating: 0.5, count: 480)
                        }
                        if isVideo {
                            setupVideoPreviewPlayer()
                        }
                        updatePreviewImage()
                    }
                }
                .onDisappear {
                    stopAudioPlayer()
                }
                
                
                .overlay {
                    if isExporting == true{
                        
                        Group{
                            // Color.black.opacity(0.3).ignoresSafeArea()
                            VStack(spacing: 12) {
                                if exportProgress > 0 {
                                    ProgressView(value: exportProgress, total: 1.0)
                                        .progressViewStyle(LinearProgressViewStyle())
                                        .padding()
                                    Text("Exporting... \(exportProgress, format: .percent.precision(.fractionLength(0)))")
                                        .foregroundColor(.primary)
                                        .bold()
                                } else {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .padding()
                                    Text("Exporting…")
                                        .foregroundColor(.primary)
                                        .bold()
                                }
                            }
                        }
                        .padding()
                        .frame(maxWidth: 300, maxHeight: 150, alignment: .center)
                        .background{
                            RoundedRectangle(cornerRadius:  8.0)
                                .fill(.background.opacity(0.3))
                        }
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
                        
                        
                    }
                    
                }
            }

         
            
        }
    }
    
    func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func previewWidth(for containerSize: CGSize) -> CGFloat {
        if isVideo {
            return min(containerSize.width - 32, 620)
        }
        return 300
    }

    private func previewHeight(for containerSize: CGSize) -> CGFloat {
        if isVideo {
            let width = previewWidth(for: containerSize)
            return min(width * 9 / 16, containerSize.height * 0.38)
        }
        return 300
    }
    
    private func pixelBufferToUIImage(_ buffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
    
    private func updatePreviewImage() {
        if isVideo {
            previewImage = nil
            return
        }

        guard let coverImage else {
            previewImage = nil
            return
        }
        if let buffer = AudioClipExporter.createPixelBuffer(from: coverImage, size: videoSize, progress: playbackProgress / (trimEnd - trimStart), startTime: trimStart, endTime: trimEnd, title: title) {
            previewImage = pixelBufferToUIImage(buffer)
        } else {
            previewImage = nil
        }
    }

    func exportClip() {
        isExporting = true
        exportProgress = 0.0

        Task {
            do {
                let url: URL
                if isVideo {
                    url = try await AudioClipExporter.exportVideoClipAsync(
                        videoURL: audioURL,
                        startTime: trimStart,
                        endTime: trimEnd
                    ) { progress in
                        Task {
                            await MainActor.run {
                                self.exportProgress = progress
                            }
                        }
                    }
                } else {
                    url = try await AudioClipExporter.exportClipAsync(
                        audioURL: audioURL,
                        title: title,
                        coverImage: coverImage ?? UIImage(),
                        startTime: trimStart,
                        endTime: trimEnd,
                        fps: 30,
                        videoSize: videoSize
                    ) { progress in
                        Task{
                            await MainActor.run {
                                self.exportProgress = progress
                            }
                        }
                    }
                }

                await MainActor.run {
                    self.exportURL = url
                    self.showShareSheet = true
                    self.isExporting = false
                }

            } catch {
                await MainActor.run {
                    print("export FAILURE: \(error)")
                    self.isExporting = false
                }
            }
        }
    }
    
    private var isPreviewPlaying: Bool {
        if isVideo {
            return videoPlayer?.rate ?? 0 > 0
        }
        return audioPlayer?.isPlaying == true
    }

    private func togglePreview() {
        if isVideo {
            toggleVideoPreview()
            return
        }

        if !audioURL.isFileURL {
            showPreviewUnavailableAlert = true
            return
        }
        if let player = audioPlayer, player.isPlaying {
            stopAudioPlayer()
        } else {
            startAudioPlayer()
        }
    }

    private func setupVideoPreviewPlayer() {
        let player = AVPlayer(url: audioURL)
        player.actionAtItemEnd = .pause
        videoPlayer = player
        seekVideoPreview(to: trimStart)
    }

    private func toggleVideoPreview() {
        guard let player = videoPlayer else {
            setupVideoPreviewPlayer()
            videoPlayer?.play()
            startProgressTimer()
            return
        }

        if player.rate > 0 {
            stopVideoPreview()
        } else {
            seekVideoPreview(to: trimStart + playbackProgress)
            player.play()
            startProgressTimer()
        }
    }

    private func seekVideoPreview(to time: Double) {
        let clampedTime = time.clamped(to: trimStart...trimEnd)
        videoPlayer?.seek(
            to: CMTime(seconds: clampedTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func stopVideoPreview() {
        videoPlayer?.pause()
        stopProgressTimer()
    }
    
    private func startAudioPlayer() {
        stopAudioPlayer()
        do {
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.currentTime = trimStart
            player.numberOfLoops = 0
            let delegate = AudioPlayerDelegateWrapper(onFinish: stopAudioPlayer)
            player.delegate = delegate
            self.audioDelegate = delegate
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            startProgressTimer()
        } catch {
            // Could not start player; silently fail
            audioPlayer = nil
            playbackProgress = 0
        }
    }
    
    private func stopAudioPlayer() {
        audioPlayer?.stop()
        audioPlayer = nil
        stopVideoPreview()
       // playbackProgress = 0
        stopProgressTimer()
        audioDelegate = nil
    }
    
    @State private var progressTimer: Timer?
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                if isVideo {
                    guard let player = videoPlayer else {
                        playbackProgress = 0
                        stopProgressTimer()
                        return
                    }

                    let progress = player.currentTime().seconds - trimStart
                    if progress >= (trimEnd - trimStart) {
                        playbackProgress = max(0, trimEnd - trimStart)
                        stopVideoPreview()
                        seekVideoPreview(to: trimStart)
                    } else {
                        playbackProgress = max(0, min(progress, trimEnd - trimStart))
                    }
                    return
                }

                guard let player = audioPlayer else {
                    playbackProgress = 0
                    stopProgressTimer()
                    return
                }
                let progress = player.currentTime - trimStart
                if progress >= (trimEnd - trimStart) {
                    stopAudioPlayer()
                } else {
                    playbackProgress = max(0, min(progress, trimEnd - trimStart))
                }
            }
        }
    }
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}

private struct VideoClipPreviewPlayerView: View {
    let player: AVPlayer

    var body: some View {
        VideoPlayer(player: player)
    }
}

// AVAudioPlayerDelegate wrapper to handle playback finished
private class AudioPlayerDelegateWrapper: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}


#Preview {
    AudioClipExportView(
        audioURL: Bundle.main.url(forResource: "sample", withExtension: "mp3")!,
        coverImageURL: URL(string: "https://example.com/cover_image.png"),
        fallbackCoverImageURL: nil,
        playPosition: 30,
        duration: 60
    )

}
