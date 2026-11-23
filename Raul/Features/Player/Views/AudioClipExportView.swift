import SwiftUI
import AVFoundation
import AVKit
import CoreImage
import TipKit
import SwiftData
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AudioClipExportView: View {
    private static let clipPlaybackRateRange: ClosedRange<Float> = 0.5...3.0
    /// Reusing one context prevents every preview frame from creating a new
    /// Metal shader/cache pipeline. Intermediate caching is unnecessary because
    /// each frame is immediately converted to a UIImage.
    private static let previewCIContext = CIContext(options: [.cacheIntermediates: false])

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable private var synchronizationStore = TranscriptSynchronizationStore.shared
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 60
    @State private var isExporting = false
    @State private var showShareSheet = false
    @State private var exportURL: URL?
    @State private var coverImage: UIImage?
    @State private var waveformSamples: [Float] = []
    @State private var audioPlayer: AVAudioPlayer?
    @State private var videoPlayer: AVPlayer?
    @State private var previewAudioSessionRequestID: UInt64 = 0
    @State private var playbackProgress: Double = 0
    @State private var audioDelegate: AudioPlayerDelegateWrapper?
    @State private var showPreviewUnavailableAlert = false
    @State private var exportProgress: Double = 0.0
    @State private var videoSize = CGSize(width: 720, height: 720)
    @State private var previewImage: UIImage?
    @State private var exportPlaybackRate: Float = 1.0
    // Visible portion of the full episode waveform; scrollable and pinch-zoomable by the user.
    @State private var windowStart: Double = 0
    @State private var windowEnd: Double = 60
    @State private var isWaveformLoading = false
    @State private var waveformLoadTask: Task<Void, Never>?
    @State private var previewUpdateTask: Task<Void, Never>?
    @State private var resolvedCaptionTimeline: ClipCaptionTimeline?
    @State private var includeCaptions = false
    @State private var showCaptionsPopup = false
    @State private var resolvingCaptions = false
    @State private var captionStatus: String?
    @State private var resolvedMediaFingerprint: String?
    @State private var clipGeneratedTimeline: ClipCaptionTimeline?
    @State private var clipGeneratedRange: ClosedRange<Double>?
    @State private var clipGeneratedMediaFingerprint: String?
    @State private var clipGenerationTask: Task<Void, Never>?
    @State private var lastExportedShareLink: ClipExportShareLink?
    @State private var exportConfirmation: String?
    private let waveformGesturesTip = ClipWaveformGesturesTip()
    var title: String? = nil
    var captionTimeline: ClipCaptionTimeline? = nil
    var episodeURL: URL? = nil
    var episodeLink: URL? = nil

    let audioURL: URL // The audio file URL to trim
    var isVideo: Bool = false
    let coverImageURL: URL? // The primary image URL to use as video background
    let fallbackCoverImageURL: URL? // The fallback image URL if primary fails
    let playPosition: Double // The center position for +/- 30s
    let duration: Double // Audio duration

    private var initialWindow: ClosedRange<Double> {
        let minTime = max(0, playPosition - 30)
        let maxTime = min(duration, playPosition + 30)
        return minTime...maxTime
    }


    var body: some View {
        GeometryReader { geometry in
            ZStack{
                
                BlurredCoverImageView(imageURL: coverImageURL ?? fallbackCoverImageURL, radius: 50)
                    .aspectRatio(1, contentMode: .fill)
                    .scaledToFill()
                    .ignoresSafeArea(.all, edges: .bottom)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(0.5)
                
                VStack(spacing: 0) {
                    clipExportHeader

                    if exportConfirmation != nil {
                        exportConfirmationView
                    }

                    ScrollView {
                        VStack(spacing: 16) {
                        
                        Group {
                            if isVideo, let videoPlayer {
                                VideoClipPreviewPlayerView(player: videoPlayer)
                                    .aspectRatio(contentMode: .fit)
                                    .background(Color.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(alignment: .center) {
                                        if let caption = activeCaption {
                                            captionPreview(caption, containerWidth: previewWidth(for: geometry.size))
                                        }
                                    }
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
                        .onChange(of: coverImage) { schedulePreviewImageUpdate() }
                        .onChange(of: trimStart) {
                            clipGenerationTask?.cancel()
                            if availableCaptionTimeline == nil { includeCaptions = false }
                            schedulePreviewImageUpdate()
                        }
                        .onChange(of: trimEnd) {
                            clipGenerationTask?.cancel()
                            if availableCaptionTimeline == nil { includeCaptions = false }
                            schedulePreviewImageUpdate()
                        }
                        .onChange(of: videoSize) { schedulePreviewImageUpdate() }
                        .onChange(of: playbackProgress) { schedulePreviewImageUpdate() }
                        
                        
                        playbackRateControl

                        VStack(alignment: .leading, spacing: 4) {
                            if availableCaptionTimeline?.captions.contains(where: { $0.cueLevel }) == true {
                                Text("Some captions highlight a whole passage.").font(.caption).foregroundStyle(.secondary)
                            }
                            if captionCoverageIsPartial {
                                Text("Captions are available for only part of this clip.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal)
                        .onChange(of: includeCaptions) { schedulePreviewImageUpdate() }
                        
                        if waveformSamples.isEmpty {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.black.opacity(0.55))
                                    .frame(height: Self.waveformHeight)
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .accent))
                            }
                            .padding(.vertical)
                        } else {
                            VStack(spacing: 10) {
                                WaveformView(
                                    samples: waveformSamples.map { max($0, 0.05) },
                                    windowStart: $windowStart,
                                    windowEnd: $windowEnd,
                                    fullDuration: duration,
                                    trimStart: trimStart,
                                    trimEnd: trimEnd,
                                    onTrimStartChanged: { newStart in
                                        setTrimStart(newStart)
                                    },
                                    onTrimEndChanged: { newEnd in
                                        setTrimEnd(newEnd)
                                    },
                                    onTrimRangeChanged: { newStart, newEnd in
                                        trimStart = newStart
                                        trimEnd = max(newEnd, newStart)
                                        stopAudioPlayer()
                                    },
                                    progress: $playbackProgress,
                                    onWindowChanged: { newWindow in
                                        // Only a pan or pinch changes the window, so the tip has been acted on.
                                        waveformGesturesTip.invalidate(reason: .actionPerformed)
                                        reloadWaveform(for: newWindow)
                                    }
                                )
                                .frame(height: Self.waveformHeight)
                                // A popover keeps the sheet's layout stable on small screens.
                                .popoverTip(waveformGesturesTip, arrowEdge: .bottom)
                                .overlay(alignment: .topTrailing) {
                                    if isWaveformLoading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .accent))
                                            .padding(6)
                                    }
                                }

                                trimReadout

                                Button {
                                    togglePreview()
                                } label: {
                                    Label(
                                        isPreviewPlaying ? "Pause" : "Preview",
                                        systemImage: isPreviewPlaying ? "pause.fill" : "play.fill"
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                            }
                            .padding(.vertical)
                        }

                        }
                        .padding()
                    }
                    .ESAFullBackground(image: coverImageURL ?? fallbackCoverImageURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.all, edges: .bottom)
                }
                
                .sheet(isPresented: $showShareSheet, onDismiss: {
                    stopAudioPlayer()
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
                    trimStart = initialWindow.lowerBound
                    trimEnd = initialWindow.upperBound
                    windowStart = initialWindow.lowerBound
                    windowEnd = initialWindow.upperBound
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
                        waveformSamples = await WaveformView.extractSamples(from: audioURL, in: initialWindow)
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
                    waveformLoadTask?.cancel()
                    previewUpdateTask?.cancel()
                    clipGenerationTask?.cancel()
                }
                .task(id: audioURL) { await resolveCaptions() }
                .onChange(of: synchronizationStore.isEnabled) {
                    Task { await resolveCaptions() }
                }
                
                
                .overlay {
                    ZStack {
                        if isExporting {
                            exportingOverlay
                                .transition(.opacity)
                        }
                    }
                    // Scoped to the overlay: animating the whole sheet on `isExporting`
                    // would also animate every control that the export disables.
                    .animation(.easeInOut(duration: 0.2), value: isExporting)
                }
            }

         
            
        }
    }

    private var clipExportHeader: some View {
        HStack(spacing: 12) {
            Button {
                stopAudioPlayer()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 52, height: 52)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close clip export")

            if isVideo == false {
                VideoSizePicker(videoSize: $videoSize)
                    .frame(maxWidth: 220)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 0)
            }

            Button {
                exportClip()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isExporting)
            .accessibilityLabel("Export clip")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var exportConfirmationView: some View {
        HStack(spacing: 10) {
            Image(systemName: lastExportedShareLink == nil ? "checkmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(exportConfirmation ?? "")
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if lastExportedShareLink != nil {
                Button("Copy Link") {
                    copyLastExportedLink()
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    private func copyLastExportedLink() {
        guard let lastExportedShareLink else { return }
        if ClipExportClipboard.copy(lastExportedShareLink.payload) {
            exportConfirmation = "Video saved · Episode link copied"
        } else {
            exportConfirmation = "Video saved · Copying the episode link was unavailable"
        }
    }
    
    func formatTime(_ time: Double) -> String {
        let total = Int(time.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Trim editing

    /// Smallest clip worth exporting; also what the waveform handles enforce.
    private static let minClipLength: Double = 1.0
    /// One tap on a nudge button. Small enough to land on a word, large enough to feel.
    private static let nudgeStep: Double = 0.5
    private static let waveformHeight: CGFloat = 92

    private func setTrimStart(_ newValue: Double) {
        let upper = max(0, trimEnd - Self.minClipLength)
        trimStart = newValue.clamped(to: 0...upper)
        stopAudioPlayer()
    }

    private func setTrimEnd(_ newValue: Double) {
        let lower = min(trimStart + Self.minClipLength, duration)
        trimEnd = newValue.clamped(to: lower...duration)
        stopAudioPlayer()
    }

    /// Start / length / end, on a material so the numbers stay legible over the cover art,
    /// with nudge buttons for the last half second that a finger on the waveform can't reach.
    private var trimReadout: some View {
        HStack(spacing: 8) {
            nudgeControl(
                title: Text("Start"),
                time: trimStart,
                canDecrease: trimStart > 0,
                canIncrease: trimStart < trimEnd - Self.minClipLength,
                onChange: setTrimStart
            )

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                Text(formatTime(trimEnd - trimStart))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("Length")
                    .font(.caption2)
                    .esaForeground(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            nudgeControl(
                title: Text("End"),
                time: trimEnd,
                canDecrease: trimEnd > trimStart + Self.minClipLength,
                canIncrease: trimEnd < duration,
                onChange: setTrimEnd
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func nudgeControl(
        title: Text,
        time: Double,
        canDecrease: Bool,
        canIncrease: Bool,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(spacing: 1) {
            title
                .font(.caption2)
                .esaForeground(.secondary)
            HStack(spacing: 6) {
                Button {
                    onChange(time - Self.nudgeStep)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(canDecrease ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .disabled(canDecrease == false)
                .accessibilityLabel(Text("Move earlier"))

                Text(formatTime(time))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()

                Button {
                    onChange(time + Self.nudgeStep)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(canIncrease ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .disabled(canIncrease == false)
                .accessibilityLabel(Text("Move later"))
            }
            .buttonStyle(.plain)
            .imageScale(.medium)
        }
        .accessibilityElement(children: .contain)
    }

    /// Opaque material rather than clear glass: over a bright blurred cover, `.primary`
    /// text on clear glass was washing out to the point of being unreadable.
    private var exportingOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.45))
                .ignoresSafeArea()

            VStack(spacing: 14) {
                if exportProgress > 0 {
                    ProgressView(value: exportProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.accent)
                    Text("Exporting… \(exportProgress, format: .percent.precision(.fractionLength(0)))")
                } else {
                    ProgressView()
                        .controlSize(.large)
                    Text("Exporting…")
                }
            }
            .font(.headline)
            .esaForeground(.primary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        }
        .accessibilityElement(children: .combine)
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

    private var clipCoversSelection: Bool {
        clipGeneratedRange.map { trimStart >= $0.lowerBound && trimEnd <= $0.upperBound } ?? false
    }

    private var availableCaptionTimeline: ClipCaptionTimeline? {
        let timeline = (clipCoversSelection ? clipGeneratedTimeline : nil) ?? captionTimeline ?? resolvedCaptionTimeline
        if let intervals = timeline?.coverage,
           !intervals.contains(where: { $0.end > trimStart && $0.start < trimEnd }) { return nil }
        return timeline?.captions.isEmpty == false ? timeline : nil
    }

    private var captionCoverageIsPartial: Bool {
        guard let intervals = availableCaptionTimeline?.coverage else { return false }
        return !intervals.contains(where: { $0.start <= trimStart && $0.end >= trimEnd })
    }

    private var activeCaption: ClipCaptionTimeline.Caption? {
        guard includeCaptions else { return nil }
        return availableCaptionTimeline?.caption(atMediaTime: trimStart + playbackProgress)
    }

    @ViewBuilder
    private func captionPreview(_ source: ClipCaptionTimeline.Caption, containerWidth: CGFloat) -> some View {
        let aspectRatio = videoSize.width / max(videoSize.height, 1)
        let previewCanvas = CGSize(width: containerWidth, height: containerWidth / max(aspectRatio, 0.1))
        let caption = AudioClipExporter.captionWindow(source, canvasSize: previewCanvas)
        if let range = Range(NSRange(location: caption.location, length: caption.length), in: caption.text) {
            let before = String(caption.text[..<range.lowerBound])
            let current = String(caption.text[range])
            let after = String(caption.text[range.upperBound...])
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = caption.speaker, speaker.isEmpty == false {
                    Text("\(speaker):")
                        .font(.headline)
                        .foregroundStyle(.green)
                }

                (Text(before) + Text(current).bold().underline() + Text(after))
                    .font(.system(size: max(12, min(containerWidth * 0.045, 32))))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: min(containerWidth * AudioClipExporter.captionWidthRatio(for: previewCanvas), 620), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
        }
    }

    @MainActor
    private func resolveCaptions() async {
        includeCaptions = false
        resolvedCaptionTimeline = nil
        resolvedMediaFingerprint = nil
        guard captionTimeline == nil, let episodeURL, audioURL.isFileURL else { return }
        resolvingCaptions = true
        defer { resolvingCaptions = false }
        let container = modelContext.container
        guard let snapshot = await EpisodeActor(modelContainer: container).clipTranscriptSnapshot(for: episodeURL) else { return }
        let mediaURL = audioURL
        let fingerprintTask = Task.detached(priority: .utility) { try TranscriptMediaFingerprint.make(for: mediaURL) }
        let fingerprint = await withTaskCancellationHandler {
            try? await fingerprintTask.value
        } onCancel: {
            fingerprintTask.cancel()
        }
        guard !Task.isCancelled, let fingerprint else { return }
        let alignment: TranscriptSynchronizationTimeline?
        switch snapshot.origin {
        case .generated:
            alignment = nil
        case .publisher(let revision):
            guard synchronizationStore.isEnabled else { return }
            if let activeAlignment = synchronizationStore.timeline(
                for: episodeURL,
                mediaFingerprint: fingerprint,
                transcriptRevision: revision
            ) {
                alignment = activeAlignment
            } else {
                alignment = await TranscriptAlignmentStoreActor(modelContainer: container).load(
                    episodeID: snapshot.episodeID, mediaFingerprint: fingerprint, transcriptRevision: revision
                )
            }
            guard synchronizationStore.isEnabled else { return }
        }
        guard !Task.isCancelled else { return }
        resolvedCaptionTimeline = ClipCaptionTimeline.resolve(
            snapshot: snapshot, mediaFingerprint: fingerprint, publisherAlignment: alignment
        )
        resolvedMediaFingerprint = fingerprint
        schedulePreviewImageUpdate()
    }

    private func startClipCaptionGeneration() {
        let start = trimStart
        let end = trimEnd
        let mediaURL = audioURL
        let selectedEpisodeURL = episodeURL
        let container = modelContext.container
        captionStatus = "Preparing clip audio…"
        clipGenerationTask = Task { @MainActor in
            defer { clipGenerationTask = nil }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                let fingerprintTask = Task.detached(priority: .utility) { try TranscriptMediaFingerprint.make(for: mediaURL) }
                let fingerprint = try await withTaskCancellationHandler {
                    try await fingerprintTask.value
                } onCancel: { fingerprintTask.cancel() }
                let asset = AVURLAsset(url: mediaURL)
                guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw AudioClipExporter.ExportError.noPlayableMedia
                }
                exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                                 end: CMTime(seconds: end, preferredTimescale: 600))
                try await exporter.export(to: output, as: .m4a)
                try Task.checkCancellation()
                captionStatus = "Generating captions…"
                let language: String?
                if let selectedEpisodeURL {
                    language = await EpisodeActor(modelContainer: container).episodeLocalFileAndLanguage(for: selectedEpisodeURL)?.1
                } else { language = nil }
                guard let results = try await TranscriptionManager.shared.transcribeClip(audioURL: output, language: language),
                      !results.isEmpty else { throw AudioClipExporter.ExportError.noPlayableMedia }
                try Task.checkCancellation()
                let lines = results.map { result in
                    TranscriptSegmentSource(text: result.text,
                        startTime: start + result.range.start.seconds, endTime: start + result.range.end.seconds,
                        timedSpans: result.timedSpans.map {
                            TranscriptTimedSpan(location: $0.location, length: $0.length,
                                startTime: start + $0.startTime, endTime: start + $0.endTime, cueLevel: $0.cueLevel)
                        })
                }
                let segments = TranscriptSegmentBuilder.makeSegments(from: lines, options: .compact)
                guard let timeline = ClipCaptionTimeline.resolve(segments: segments, publisherAlignmentRequired: false, alignment: nil),
                      !timeline.captions.isEmpty else { throw AudioClipExporter.ExportError.noPlayableMedia }
                clipGeneratedTimeline = timeline
                clipGeneratedRange = start...end
                clipGeneratedMediaFingerprint = fingerprint
                includeCaptions = true
                captionStatus = "Clip captions are kept separate from the episode transcript."
                schedulePreviewImageUpdate()
            } catch is CancellationError {
                captionStatus = nil
            } catch {
                captionStatus = "Could not generate captions for this clip. You can export without captions."
            }
        }
    }
    
    private func pixelBufferToUIImage(_ buffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        if let cgImage = Self.previewCIContext.createCGImage(ciImage, from: ciImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }

    /// Coalesce high-frequency trim and playback changes. Playback progress is
    /// sampled every 50 ms, but rebuilding a 720x720 pixel buffer at that rate is
    /// unnecessary for an editor preview and caused sustained file-backed Metal
    /// writes. This caps preview rendering at roughly 6 frames per second.
    private func schedulePreviewImageUpdate() {
        guard previewUpdateTask == nil else { return }
        previewUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard Task.isCancelled == false else { return }
            previewUpdateTask = nil
            updatePreviewImage()
        }
    }
    
    private func reloadWaveform(for window: ClosedRange<Double>) {
        waveformLoadTask?.cancel()
        isWaveformLoading = true
        waveformLoadTask = Task {
            var samples = await WaveformView.extractSamples(from: audioURL, in: window)
            if Task.isCancelled { return }
            if samples.allSatisfy({ $0 < 0.07 }) {
                samples = Array(repeating: 0.5, count: samples.count)
            }
            await MainActor.run {
                self.waveformSamples = samples
                self.windowStart = window.lowerBound
                self.windowEnd = window.upperBound
                self.isWaveformLoading = false
            }
        }
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
        let segmentDuration = max(trimEnd - trimStart, 0.001)
        let normalizedProgress = min(max(playbackProgress / segmentDuration, 0), 1)
        if let buffer = AudioClipExporter.createPixelBuffer(
            from: coverImage,
            size: videoSize,
            progress: normalizedProgress,
            startTime: trimStart,
            endTime: trimEnd,
            playbackRate: exportPlaybackRate,
            title: title,
            caption: activeCaption
        ) {
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
                if includeCaptions, captionTimeline == nil {
                    let mediaURL = audioURL
                    let fingerprint = try await Task.detached(priority: .utility) {
                        try TranscriptMediaFingerprint.make(for: mediaURL)
                    }.value
                    let expected = clipCoversSelection && clipGeneratedTimeline != nil
                        ? clipGeneratedMediaFingerprint : resolvedMediaFingerprint
                    guard fingerprint == expected else {
                        includeCaptions = false
                        resolvedCaptionTimeline = nil
                        clipGeneratedTimeline = nil
                        clipGeneratedMediaFingerprint = nil
                        captionStatus = "The audio changed. Generate or check captions again."
                        isExporting = false
                        return
                    }
                }
                let url: URL
                if isVideo {
                    url = try await AudioClipExporter.exportVideoClipAsync(
                        videoURL: audioURL,
                        startTime: trimStart,
                        endTime: trimEnd,
                        playbackRate: exportPlaybackRate,
                        captionTimeline: includeCaptions ? availableCaptionTimeline : nil
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
                        playbackRate: exportPlaybackRate,
                        fps: 30,
                        videoSize: videoSize,
                        captionTimeline: includeCaptions ? availableCaptionTimeline : nil
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
                    let shareLink = ClipExportShareLinkBuilder.make(
                        episodeLink: self.episodeLink,
                        fallbackURL: self.episodeURL,
                        startTime: self.trimStart
                    )
                    self.lastExportedShareLink = shareLink
                    if let shareLink {
                        let copied = ClipExportClipboard.copy(shareLink.payload)
                        self.exportConfirmation = copied
                            ? "Video saved · Episode link copied"
                            : "Video saved · Copying the episode link was unavailable"
                    } else {
                        self.exportConfirmation = "Video saved · Episode link unavailable"
                    }
                    self.showShareSheet = true
                    self.isExporting = false
                }

            } catch {
                await MainActor.run {
                    AppDiagnostics.log("clip_export_failed")
                    self.isExporting = false
                    self.captionStatus = "Could not export the clip. Try again."
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
        Task {
            let asset = AVURLAsset(url: audioURL)
            guard let tracks = try? await asset.loadTracks(withMediaType: .video),
                  let track = tracks.first,
                  let naturalSize = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else { return }
            let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
            let displaySize = CGSize(width: abs(bounds.width), height: abs(bounds.height))
            guard displaySize.width > 0, displaySize.height > 0 else { return }
            videoSize = displaySize
        }
    }

    private func toggleVideoPreview() {
        guard let player = videoPlayer else {
            setupVideoPreviewPlayer()
            startPreviewWithAudioSession {
                guard self.videoPlayer != nil else { return }
                self.videoPlayer?.playImmediately(atRate: self.exportPlaybackRate)
                self.startProgressTimer()
            }
            return
        }

        if player.rate > 0 {
            stopVideoPreview()
        } else {
            seekVideoPreview(to: trimStart + playbackProgress)
            startPreviewWithAudioSession {
                guard self.videoPlayer === player else { return }
                player.playImmediately(atRate: self.exportPlaybackRate)
                self.startProgressTimer()
            }
        }
    }

    private func startPreviewWithAudioSession(_ start: @escaping @MainActor () -> Void) {
        previewAudioSessionRequestID &+= 1
        let requestID = previewAudioSessionRequestID
#if os(iOS)
        Task { @MainActor in
            guard await AudioSessionConfigurator.activateForPlayback() == nil,
                  self.previewAudioSessionRequestID == requestID else { return }
            start()
        }
#else
        start()
#endif
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
        previewAudioSessionRequestID &+= 1
        videoPlayer?.pause()
        stopProgressTimer()
    }
    
    private func startAudioPlayer() {
        stopAudioPlayer()
        do {
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.enableRate = true
            player.rate = exportPlaybackRate
            player.currentTime = trimStart
            player.numberOfLoops = 0
            let delegate = AudioPlayerDelegateWrapper(onFinish: stopAudioPlayer)
            player.delegate = delegate
            self.audioDelegate = delegate
            player.prepareToPlay()
            audioPlayer = player
            startPreviewWithAudioSession {
                guard self.audioPlayer === player else { return }
                player.play()
                self.startProgressTimer()
            }
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

    private var playbackRateControl: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { rate in
                    Button {
                        setExportPlaybackRate(Float(rate))
                    } label: {
                        if abs(Double(exportPlaybackRate) - rate) < 0.01 {
                            Label(Float(rate).formattedPlaybackSpeed, systemImage: "checkmark")
                        } else {
                            Text(Float(rate).formattedPlaybackSpeed)
                        }
                    }
                }
            } label: {
                Label(exportPlaybackRate.formattedPlaybackSpeed, systemImage: "gauge.with.dots.needle.50percent")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Playback speed")
            .accessibilityValue(exportPlaybackRate.formattedPlaybackSpeed)

            Button {
                if availableCaptionTimeline == nil {
                    showCaptionsPopup = true
                } else {
                    includeCaptions.toggle()
                    schedulePreviewImageUpdate()
                }
            } label: {
                Image(systemName: includeCaptions ? "captions.bubble.fill" : "captions.bubble")
                    .font(.title3)
                    .frame(width: 44, height: 40)
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
            }
            .background(
                includeCaptions ? Color.accentColor : Color.black.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Captions")
            .accessibilityValue(availableCaptionTimeline == nil ? "Unavailable" : (includeCaptions ? "On" : "Off"))
            .accessibilityHint(availableCaptionTimeline == nil ? "Shows caption availability and generation options." : "Shows highlighted captions in preview and export.")
            .popover(isPresented: $showCaptionsPopup, arrowEdge: .bottom) {
                captionsPopup
                    .frame(width: 280)
                    .padding()
                    .presentationCompactAdaptation(.popover)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .onChange(of: exportPlaybackRate) { _, _ in
            if let player = audioPlayer { player.rate = exportPlaybackRate }
            if videoPlayer?.rate ?? 0 > 0 { videoPlayer?.rate = exportPlaybackRate }
            schedulePreviewImageUpdate()
        }
    }

    private func setExportPlaybackRate(_ rate: Float) {
        exportPlaybackRate = rate.clamped(to: Self.clipPlaybackRateRange)
    }

    @ViewBuilder
    private var captionsPopup: some View {
        VStack(alignment: .leading, spacing: 12) {
            if resolvingCaptions {
                Label("Checking captions…", systemImage: "ellipsis.bubble")
                    .foregroundStyle(.secondary)
            } else if availableCaptionTimeline != nil {
                Label("Captions are ready", systemImage: "captions.bubble.fill")
                Text("Tap Captions to turn the overlay on or off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Captions are unavailable for this media.")
                    .font(.subheadline)
                if audioURL.isFileURL {
                    Button(clipGenerationTask == nil ? "Generate captions for clip" : "Cancel caption generation") {
                        if let clipGenerationTask {
                            clipGenerationTask.cancel()
                        } else {
                            startClipCaptionGeneration()
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.black.opacity(0.78), in: Capsule())
                    .buttonStyle(.plain)
                    .disabled(resolvingCaptions)
                } else {
                    Text("Download this episode to generate clip captions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let captionStatus {
                Text(captionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct VideoClipPreviewPlayerView: View {
    let player: AVPlayer

    var body: some View {
        VideoPlayer(player: player)
    }
}

private extension Float {
    var formattedPlaybackSpeed: String {
        String(format: "%.1fx", self)
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

struct ClipExportShareLink: Equatable, Sendable {
    let url: URL
    let payload: String
    let timecode: String
}

enum ClipExportShareLinkBuilder {
    static func make(episodeLink: URL?, fallbackURL: URL?, startTime: Double) -> ClipExportShareLink? {
        guard let url = [episodeLink, fallbackURL]
            .compactMap({ $0 })
            .first(where: isShareableURL) else {
            return nil
        }

        let timecode = formatTimecode(startTime)
        let destination = timestampedURL(for: url, startTime: startTime) ?? url
        return ClipExportShareLink(
            url: destination,
            payload: "\(destination.absoluteString)\n\nAt \(timecode)",
            timecode: timecode
        )
    }

    static func formatTimecode(_ time: Double) -> String {
        let total = max(0, Int(time.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func isShareableURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.isEmpty == false,
              url.user == nil, url.password == nil else {
            return false
        }
        return true
    }

    /// Only add a timestamp query for destinations whose public URL format documents it.
    /// Podcast episode pages are otherwise left untouched so the copied link cannot be
    /// broken by an unsupported `?t=` parameter.
    private static func timestampedURL(for url: URL, startTime: Double) -> URL? {
        let seconds = max(0, Int(startTime.rounded()))
        guard seconds > 0,
              let host = url.host?.lowercased(),
              host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.lowercased() == "t" }
        queryItems.append(URLQueryItem(name: "t", value: String(seconds)))
        components.queryItems = queryItems
        return components.url
    }
}

@MainActor
enum ClipExportClipboard {
    static func copy(_ payload: String) -> Bool {
#if os(iOS)
        UIPasteboard.general.string = payload
        return true
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(payload, forType: .string)
#else
        return false
#endif
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
