import SwiftUI
import AVFoundation

/// A view that draws the waveform for a segment of audio.
/// The visible time span can be panned and pinch-zoomed by the user to scrub through and
/// precisely select any part of `fullDuration`. `windowStart`/`windowEnd` reflect the range
/// that `samples` was actually decoded for (it lags slightly behind the live gesture while a
/// reload is in flight); the view tracks the user's live intent separately so panning/zooming
/// always feels immediate, and cross-fades to the freshly decoded samples once they arrive.
struct WaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let samples: [Float]          // Normalized audio samples in 0...1, covering windowStart...windowEnd
    @Binding var windowStart: Double
    @Binding var windowEnd: Double
    let fullDuration: Double
    let trimStart: Double
    let trimEnd: Double
    let onTrimStartChanged: (Double) -> Void
    let onTrimEndChanged: (Double) -> Void
    @Binding var progress: Double
    /// Called after a pan or pinch gesture ends with the new desired window, so the caller can reload samples for it.
    var onWindowChanged: (ClosedRange<Double>) -> Void = { _ in }

    // How far inside (in seconds) the handles/overlays should start/end from the waveform edges.
    // Default to 10 seconds as requested.
    var insetSeconds: Double = 0.0

    // Minimum visible span while zoomed in, so the user can't zoom past what's meaningful to select.
    private static let minWindowSpan: Double = 3.0

    // The window the user is currently looking at, live during gestures. Decoupled from
    // `windowStart`/`windowEnd` (which track the currently *loaded* samples) so consecutive
    // pan/zoom gestures always feel instant, independent of how long a reload takes.
    @State private var visibleStart: Double = 0
    @State private var visibleEnd: Double = 60
    @State private var panBaseWindow: (start: Double, end: Double)?
    @State private var pinchBaseWindow: (start: Double, end: Double)?

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 0.1
            let capsuleWidth = (geo.size.width - spacing * CGFloat(max(samples.count - 1, 0))) / CGFloat(samples.count)

            // Time span currently shown to the user (live, not the possibly-stale loaded window)
            let totalTime = visibleEnd - visibleStart
            // Prevent division by zero
            let safeTotalTime = max(totalTime, 0.0001)
            // Convert inset seconds to pixels, but clamp so we never exceed half width
            let secondsPerPixel = safeTotalTime / geo.size.width
            let rawInsetPixels = CGFloat(insetSeconds / max(secondsPerPixel, 0.0001))
            let insetPixels = min(rawInsetPixels, geo.size.width * 0.45) // keep at least 10% usable width
            let effectiveWidth = max(geo.size.width - 2 * insetPixels, 1)

            // Transform that maps the bars (laid out for windowStart...windowEnd) onto the
            // currently visible window, so they slide/scale live under the gesture without
            // waiting for a reload.
            let loadedSpan = max(windowEnd - windowStart, 0.0001)
            let barsScale = loadedSpan / safeTotalTime
            let barsOffset = geo.size.width * CGFloat((windowStart - visibleStart) / safeTotalTime)

            ZStack(alignment: .bottom) {
                // Waveform
                HStack(spacing: spacing) {
                    ForEach(samples.indices, id: \.self) { sampleIndex in
                        let sample = samples[sampleIndex]
                        Capsule()
                            .fill(Color.accent.opacity(0.7))
                            .frame(width: max(1, capsuleWidth), height: max(2, CGFloat(sample) * geo.size.height))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .easeInOut, value: samples)
                .scaleEffect(x: barsScale, y: 1, anchor: .leading)
                .offset(x: barsOffset)
                // The pan/zoom transform must snap instantly to match the live gesture and to
                // disappear the moment freshly decoded samples land — animating it (e.g. via an
                // ancestor's `.animation(value:)`) makes the zoomed-in waveform visibly shrink
                // back to identity before the swap, which reads as "snapping back".
                .transaction { $0.animation = nil }

                // Progress line (only within [trimStart, trimEnd])
                if trimEnd > trimStart, progress >= 0, progress <= (trimEnd - trimStart) {
                    let progressX = position(for: trimStart + progress, in: geo.size.width, inset: insetPixels, effectiveWidth: effectiveWidth)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 3, height: geo.size.height)
                        .position(x: progressX, y: geo.size.height / 2)
                        .allowsHitTesting(true)
                }

                // Trim overlays (dimmed regions outside the selected range)
                trimOverlay(color: Color.accent.opacity(0.8),
                            from: 0,
                            to: position(for: trimStart, in: geo.size.width, inset: insetPixels, effectiveWidth: effectiveWidth))

                trimOverlay(color: Color.accent.opacity(0.8),
                            from: position(for: trimEnd, in: geo.size.width, inset: insetPixels, effectiveWidth: effectiveWidth),
                            to: geo.size.width)

                // Trim handles
                trimHandle(
                    x: position(for: trimStart, in: geo.size.width, inset: insetPixels, effectiveWidth: effectiveWidth),
                    color: .accent,
                    systemName: "arrow.left",
                    onDrag: { x in
                        // Convert x back to time respecting inset/effectiveWidth
                        let clampedX = max(insetPixels, min(x, insetPixels + effectiveWidth))
                        let percent = (clampedX - insetPixels) / effectiveWidth
                        let newTime = visibleStart + (safeTotalTime * percent)
                        onTrimStartChanged(newTime.clamped(to: 0...trimEnd))
                    }
                )

                trimHandle(
                    x: position(for: trimEnd, in: geo.size.width, inset: insetPixels, effectiveWidth: effectiveWidth),
                    color: .accent,
                    systemName: "arrow.right",
                    onDrag: { x in
                        // Convert x back to time respecting inset/effectiveWidth
                        let clampedX = max(insetPixels, min(x, insetPixels + effectiveWidth))
                        let percent = (clampedX - insetPixels) / effectiveWidth
                        let newTime = visibleStart + (safeTotalTime * percent)
                        onTrimEndChanged(newTime.clamped(to: trimStart...fullDuration))
                    }
                )
            }
            .contentShape(Rectangle())
            .highPriorityGesture(zoomGesture())
            .gesture(panGesture(width: geo.size.width))
            .clipped()
        }
        .frame(height: 60)
        .onAppear {
            visibleStart = windowStart
            visibleEnd = windowEnd
        }
        .onChange(of: windowStart) { _, newValue in
            if panBaseWindow == nil && pinchBaseWindow == nil { visibleStart = newValue }
        }
        .onChange(of: windowEnd) { _, newValue in
            if panBaseWindow == nil && pinchBaseWindow == nil { visibleEnd = newValue }
        }
    }

    // Pan: drag left/right to scroll the visible window earlier/later in the episode.
    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let base = panBaseWindow ?? (visibleStart, visibleEnd)
                if panBaseWindow == nil { panBaseWindow = base }
                guard width > 0 else { return }
                let span = base.end - base.start
                let timePerPixel = span / Double(width)
                // Dragging right reveals earlier content; dragging left reveals later content.
                let deltaTime = -Double(value.translation.width) * timePerPixel
                let clamped = clampedWindow(newStart: base.start + deltaTime, newEnd: base.end + deltaTime)
                visibleStart = clamped.start
                visibleEnd = clamped.end
            }
            .onEnded { _ in
                panBaseWindow = nil
                onWindowChanged(visibleStart...visibleEnd)
            }
    }

    // Pinch: zoom the visible window in/out around its center to select more precisely or span more time.
    private func zoomGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let base = pinchBaseWindow ?? (visibleStart, visibleEnd)
                if pinchBaseWindow == nil { pinchBaseWindow = base }
                let originalSpan = base.end - base.start
                let center = (base.start + base.end) / 2
                let minSpan = min(Self.minWindowSpan, fullDuration)
                let maxSpan = max(fullDuration, minSpan)
                let newSpan = (originalSpan / max(Double(value), 0.01)).clamped(to: minSpan...maxSpan)
                let clamped = clampedWindow(newStart: center - newSpan / 2, newEnd: center + newSpan / 2)
                visibleStart = clamped.start
                visibleEnd = clamped.end
            }
            .onEnded { _ in
                pinchBaseWindow = nil
                onWindowChanged(visibleStart...visibleEnd)
            }
    }

    // Keeps a proposed window within 0...fullDuration without changing its span, unless the span itself doesn't fit.
    private func clampedWindow(newStart: Double, newEnd: Double) -> (start: Double, end: Double) {
        var start = newStart
        var end = newEnd
        let span = end - start
        if span >= fullDuration {
            start = 0
            end = fullDuration
        } else if start < 0 {
            start = 0
            end = span
        } else if end > fullDuration {
            end = fullDuration
            start = fullDuration - span
        }
        return (start, end)
    }

    // Helper: position for a time value with inset-aware mapping, relative to the live visible window
    func position(for time: Double, in width: CGFloat, inset: CGFloat, effectiveWidth: CGFloat) -> CGFloat {
        let total = max(visibleEnd - visibleStart, 0.0001)
        let percent = CGFloat((time - visibleStart) / total)
        return inset + percent * effectiveWidth
    }

    // Trim overlay
    func trimOverlay(color: Color, from: CGFloat, to: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(to - from, 0), height: 60)
            .position(x: from + (to-from)/2, y: 30)
    }

    // Trim handle
    func trimHandle(x: CGFloat, color: Color, systemName: String, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 5, height: 60)
            // .overlay(Image(systemName: systemName).foregroundColor(.black))
            .position(x: x, y: 30)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onDrag(value.location.x)
                    }
            )
            .shadow(radius: 2)
    }
}

// MARK: - Audio sample extraction
extension WaveformView {
    /// Extract normalized samples for the specified time range of the audio file.
    static func extractSamples(from url: URL, in range: ClosedRange<Double>, sampleCount: Int = 120) async -> [Float] {
        let fallback = Array(repeating: Float(0.05), count: sampleCount)
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return fallback }
        guard let assetReader = try? AVAssetReader(asset: asset) else { return fallback }
        let timeRange = CMTimeRange(start: .init(seconds: range.lowerBound, preferredTimescale: 600), duration: .init(seconds: range.upperBound-range.lowerBound, preferredTimescale: 600))
        assetReader.timeRange = timeRange
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16
        ])
        guard assetReader.canAdd(output) else { return fallback }
        assetReader.add(output)
        guard assetReader.startReading() else { return fallback }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), CMSampleBufferIsValid(buffer) {
            if let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var data = Data(count: length)
                _ = data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
                }
                let int16Samples = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Int16] in
                    let bufferPointer = ptr.bindMemory(to: Int16.self)
                    return Array(bufferPointer)
                }
                let floats = int16Samples.map { abs(Float($0)) / Float(Int16.max) }
                samples.append(contentsOf: floats)
            }
        }
        assetReader.cancelReading()
        // Downsample to sampleCount using RMS per window
        let windowSize = max(samples.count / sampleCount, 1)
        var downsampled: [Float] = []
        for i in 0..<sampleCount {
            let start = i * windowSize
            let end = min(start + windowSize, samples.count)
            if start < end {
                let window = samples[start..<end]
                let rms = sqrt(window.map { $0 * $0 }.reduce(0, +) / Float(window.count))
                let scaled = min(rms * 3, 1.0)
                downsampled.append(scaled)
            } else {
                downsampled.append(0.05)
            }
        }
        return downsampled
    }
}
