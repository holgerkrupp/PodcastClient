import SwiftUI
import AVFoundation

/// A view that draws the waveform for a segment of audio and lets the user place the
/// clip's in/out markers on it.
///
/// The visible time span can be panned and pinch-zoomed to scrub through and precisely
/// select any part of `fullDuration`. `windowStart`/`windowEnd` reflect the range that
/// `samples` was actually decoded for (it lags slightly behind the live gesture while a
/// reload is in flight); the view tracks the user's live intent separately so
/// panning/zooming always feels immediate, and cross-fades to the freshly decoded
/// samples once they arrive.
///
/// Interaction model, in decreasing gesture priority:
/// * dragging a handle moves that marker (with a generous invisible hit area, and the
///   window auto-scrolls when the finger reaches an edge, so a marker can be placed
///   outside the currently visible span without letting go),
/// * dragging the selected band moves the whole selection, keeping its length,
/// * dragging anywhere else pans the window,
/// * pinching zooms around the pinch's anchor point, at any time,
/// * double-tapping zooms to fit the current selection.
struct WaveformView: View {
    enum DragTarget: Equatable { case start, end, selection }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let samples: [Float]          // Normalized audio samples in 0...1, covering windowStart...windowEnd
    @Binding var windowStart: Double
    @Binding var windowEnd: Double
    let fullDuration: Double
    let trimStart: Double
    let trimEnd: Double
    let onTrimStartChanged: (Double) -> Void
    let onTrimEndChanged: (Double) -> Void
    /// Called when the whole selection is dragged, so both markers move in one update.
    var onTrimRangeChanged: ((Double, Double) -> Void)? = nil
    @Binding var progress: Double
    /// Called after a pan, pinch or edge-scroll ends with the new desired window, so the caller can reload samples for it.
    var onWindowChanged: (ClosedRange<Double>) -> Void = { _ in }

    // Minimum visible span while zoomed in, so the user can't zoom past what's meaningful to select.
    private static let minWindowSpan: Double = 2.0
    // Shortest clip the handles will let the user create.
    private static let minSelectionSpan: Double = 1.0
    // The handles are drawn narrow but grabbed wide: a 5pt target was the main reason
    // placing a marker felt fiddly.
    private static let handleWidth: CGFloat = 11
    private static let handleHitWidth: CGFloat = 44
    // While dragging a marker, holding the finger this close to an edge scrolls the window.
    private static let edgeScrollZone: CGFloat = 34
    // Fastest auto-scroll, as a fraction of the visible span per second.
    private static let maxEdgeScrollRate: Double = 0.9
    private static let bubbleBoxWidth: CGFloat = 68

    // The window the user is currently looking at, live during gestures. Decoupled from
    // `windowStart`/`windowEnd` (which track the currently *loaded* samples) so consecutive
    // pan/zoom gestures always feel instant, independent of how long a reload takes.
    @State private var visibleStart: Double = 0
    @State private var visibleEnd: Double = 60
    @State private var panBaseWindow: (start: Double, end: Double)?
    @State private var pinchBaseWindow: (start: Double, end: Double)?

    // Marker dragging
    @State private var dragTarget: DragTarget?
    /// Seconds between the finger and the value it grabbed, so a marker never jumps to the touch.
    @State private var grabOffset: Double = 0
    @State private var grabbedSelectionSpan: Double = 0
    @State private var pointerX: CGFloat = 0
    @State private var viewWidth: CGFloat = 1
    @State private var edgeScrollVelocity: Double = 0
    @State private var edgeScrollTask: Task<Void, Never>?
    /// Bumped whenever an edge-scroll loop starts or is stopped, so a loop that wakes up
    /// after being cancelled can't clear a successor's task handle.
    @State private var edgeScrollGeneration = 0
    @State private var windowMovedDuringDrag = false

    private var visibleSpan: Double { max(visibleEnd - visibleStart, 0.0001) }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)
            let startX = x(for: trimStart, width: width)
            let endX = x(for: trimEnd, width: width)

            ZStack(alignment: .topLeading) {
                Color.clear // establishes the ZStack's coordinate space at the full size

                bars(width: width, height: height)

                // Dim what is not part of the clip. A neutral scrim (rather than a coloured
                // block) keeps the unselected audio visible as context instead of hiding it.
                scrim(from: 0, to: startX, height: height)
                scrim(from: endX, to: width, height: height)

                selectionBorder(startX: startX, endX: endX, height: height)
                progressIndicator(width: width, height: height)

                // Hit target for moving the whole selection. Sits under the handles so the
                // handles keep priority where they overlap.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(width: max(endX - startX, 0), height: height)
                    .offset(x: startX)
                    .highPriorityGesture(markerDrag(target: .selection, width: width))
                    .allowsHitTesting(onTrimRangeChanged != nil && endX - startX > Self.handleHitWidth)

                handle(target: .start, x: startX, height: height, width: width)
                handle(target: .end, x: endX, height: height, width: width)

                if let dragTarget, dragTarget != .selection {
                    timeBubble(
                        time: dragTarget == .start ? trimStart : trimEnd,
                        x: dragTarget == .start ? startX : endX,
                        width: width
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(panGesture(width: width))
            .simultaneousGesture(zoomGesture())
            .onTapGesture(count: 2) { zoomToSelection() }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onAppear { viewWidth = width }
            .onChange(of: width) { _, newValue in viewWidth = newValue }
        }
        .background {
            // The waveform owns its backdrop so its contrast never depends on whatever
            // cover art happens to be blurred behind the sheet.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .sensoryFeedback(.selection, trigger: dragTarget)
        .onAppear {
            visibleStart = windowStart
            visibleEnd = windowEnd
        }
        .onDisappear { stopEdgeScroll() }
        .onChange(of: windowStart) { _, newValue in
            if isIdle { visibleStart = newValue }
        }
        .onChange(of: windowEnd) { _, newValue in
            if isIdle { visibleEnd = newValue }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Clip selection"))
        .accessibilityValue(Text("From \(Self.accessibilityTime(trimStart)) to \(Self.accessibilityTime(trimEnd))"))
    }

    private var isIdle: Bool {
        panBaseWindow == nil && pinchBaseWindow == nil && dragTarget == nil
    }

    // MARK: - Pieces

    private func bars(width: CGFloat, height: CGFloat) -> some View {
        let spacing: CGFloat = 1
        let count = max(samples.count, 1)
        let barWidth = max((width - spacing * CGFloat(count - 1)) / CGFloat(count), 1)
        // Transform that maps the bars (laid out for windowStart...windowEnd) onto the
        // currently visible window, so they slide/scale live under the gesture without
        // waiting for a reload.
        let loadedSpan = max(windowEnd - windowStart, 0.0001)
        let barsScale = loadedSpan / visibleSpan
        let barsOffset = width * CGFloat((windowStart - visibleStart) / visibleSpan)

        return HStack(spacing: spacing) {
            ForEach(samples.indices, id: \.self) { index in
                Capsule()
                    .fill(barColor(at: index, loadedSpan: loadedSpan))
                    .frame(width: barWidth, height: max(2, CGFloat(samples[index]) * (height - 8)))
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
    }

    /// Bars inside the clip are accented, the rest stay a muted grey, so the selection is
    /// readable even before the scrim is taken into account.
    private func barColor(at index: Int, loadedSpan: Double) -> Color {
        let fraction = (Double(index) + 0.5) / Double(max(samples.count, 1))
        let time = windowStart + fraction * loadedSpan
        return (time >= trimStart && time <= trimEnd)
            ? Color.accentColor
            : Color.white.opacity(0.28)
    }

    private func scrim(from: CGFloat, to: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.45))
            .frame(width: max(to - from, 0), height: height)
            .offset(x: from)
            .allowsHitTesting(false)
    }

    private func selectionBorder(startX: CGFloat, endX: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
            .frame(width: max(endX - startX, 0), height: height)
            .offset(x: startX)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func progressIndicator(width: CGFloat, height: CGFloat) -> some View {
        if trimEnd > trimStart, progress >= 0, progress <= (trimEnd - trimStart) {
            let progressX = x(for: trimStart + progress, width: width)
            Capsule()
                .fill(Color.white)
                .frame(width: 2, height: height)
                .offset(x: progressX - 1)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .allowsHitTesting(false)
        }
    }

    private func handle(target: DragTarget, x handleX: CGFloat, height: CGFloat, width: CGFloat) -> some View {
        let isActive = dragTarget == target
        return ZStack {
            RoundedRectangle(cornerRadius: Self.handleWidth / 2, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: Self.handleWidth, height: height)
                .overlay {
                    // Grip lines make the bar read as something you can grab.
                    VStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule()
                                .fill(Color.black.opacity(0.45))
                                .frame(width: 1.5, height: 3)
                        }
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 3)
                .scaleEffect(isActive ? 1.15 : 1, anchor: .center)
                .animation(reduceMotion ? nil : .spring(duration: 0.2), value: isActive)
        }
        .frame(width: Self.handleHitWidth, height: height)
        .contentShape(Rectangle())
        .offset(x: handleX - Self.handleHitWidth / 2)
        .highPriorityGesture(markerDrag(target: target, width: width))
    }

    private func timeBubble(time: Double, x bubbleX: CGFloat, width: CGFloat) -> some View {
        Text(Self.shortTime(time))
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: .black.opacity(0.4), radius: 3)
            .fixedSize()
            // A fixed-width box centres the bubble on the marker whatever the digit count is.
            .frame(width: Self.bubbleBoxWidth)
            // Keep the bubble inside the view when the marker is near an edge.
            .offset(
                x: bubbleX.clamped(to: (Self.bubbleBoxWidth / 2)...max(Self.bubbleBoxWidth / 2, width - Self.bubbleBoxWidth / 2))
                    - Self.bubbleBoxWidth / 2,
                y: 4
            )
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: - Marker gestures

    private func markerDrag(target: DragTarget, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A two-finger pinch also feeds the drag recognizer; ignore it so the
                // markers don't lurch while zooming.
                guard pinchBaseWindow == nil else { return }
                if dragTarget != target {
                    dragTarget = target
                    windowMovedDuringDrag = false
                    let grabbedTime = time(forX: value.startLocation.x, width: width)
                    switch target {
                    case .start:
                        grabOffset = trimStart - grabbedTime
                    case .end:
                        grabOffset = trimEnd - grabbedTime
                    case .selection:
                        grabOffset = trimStart - grabbedTime
                        grabbedSelectionSpan = max(trimEnd - trimStart, 0)
                    }
                }
                pointerX = value.location.x
                viewWidth = width
                applyPointerDrag(width: width)
                updateEdgeScroll(width: width)
            }
            .onEnded { _ in
                stopEdgeScroll()
                dragTarget = nil
                grabOffset = 0
                if windowMovedDuringDrag {
                    windowMovedDuringDrag = false
                    onWindowChanged(visibleStart...visibleEnd)
                }
            }
    }

    /// Maps the current finger position back to a time and moves whatever is being dragged.
    /// Called both while the finger moves and while the window auto-scrolls under a still finger.
    private func applyPointerDrag(width: CGFloat) {
        guard let target = dragTarget else { return }
        let proposed = time(forX: pointerX, width: width) + grabOffset
        switch target {
        case .start:
            let upper = max(0, trimEnd - Self.minSelectionSpan)
            onTrimStartChanged(proposed.clamped(to: 0...upper))
        case .end:
            let lower = min(trimStart + Self.minSelectionSpan, fullDuration)
            onTrimEndChanged(proposed.clamped(to: lower...fullDuration))
        case .selection:
            guard let onTrimRangeChanged else { return }
            let span = min(grabbedSelectionSpan, fullDuration)
            let newStart = proposed.clamped(to: 0...max(0, fullDuration - span))
            onTrimRangeChanged(newStart, newStart + span)
        }
    }

    // MARK: - Edge auto-scroll

    private func updateEdgeScroll(width: CGFloat) {
        let span = visibleSpan
        var velocity: Double = 0
        if pointerX < Self.edgeScrollZone {
            let intensity = Double((Self.edgeScrollZone - max(pointerX, 0)) / Self.edgeScrollZone).clamped(to: 0...1)
            velocity = -intensity * span * Self.maxEdgeScrollRate
        } else if pointerX > width - Self.edgeScrollZone {
            let intensity = Double((pointerX - (width - Self.edgeScrollZone)) / Self.edgeScrollZone).clamped(to: 0...1)
            velocity = intensity * span * Self.maxEdgeScrollRate
        }
        edgeScrollVelocity = velocity
        if velocity != 0 {
            startEdgeScroll()
        } else {
            edgeScrollTask?.cancel()
            edgeScrollTask = nil
        }
    }

    private func startEdgeScroll() {
        guard edgeScrollTask == nil else { return }
        edgeScrollGeneration += 1
        let generation = edgeScrollGeneration
        edgeScrollTask = Task { @MainActor in
            let step = 1.0 / 60.0
            while Task.isCancelled == false, dragTarget != nil, edgeScrollVelocity != 0 {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { break }
                let delta = edgeScrollVelocity * step
                let clamped = clampedWindow(newStart: visibleStart + delta, newEnd: visibleEnd + delta)
                // Already against the start or end of the episode: nothing left to scroll to.
                if clamped.start == visibleStart && clamped.end == visibleEnd { break }
                visibleStart = clamped.start
                visibleEnd = clamped.end
                windowMovedDuringDrag = true
                applyPointerDrag(width: viewWidth)
            }
            if edgeScrollGeneration == generation { edgeScrollTask = nil }
        }
    }

    private func stopEdgeScroll() {
        edgeScrollGeneration += 1
        edgeScrollTask?.cancel()
        edgeScrollTask = nil
        edgeScrollVelocity = 0
    }

    // MARK: - Window gestures

    // Pan: drag left/right to scroll the visible window earlier/later in the episode.
    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard dragTarget == nil, pinchBaseWindow == nil, width > 0 else { return }
                let base = panBaseWindow ?? (visibleStart, visibleEnd)
                if panBaseWindow == nil { panBaseWindow = base }
                let span = base.end - base.start
                let timePerPixel = span / Double(width)
                // Dragging right reveals earlier content; dragging left reveals later content.
                let deltaTime = -Double(value.translation.width) * timePerPixel
                let clamped = clampedWindow(newStart: base.start + deltaTime, newEnd: base.end + deltaTime)
                visibleStart = clamped.start
                visibleEnd = clamped.end
            }
            .onEnded { _ in
                guard panBaseWindow != nil else { return }
                panBaseWindow = nil
                onWindowChanged(visibleStart...visibleEnd)
            }
    }

    // Pinch: zoom in/out around the point between the fingers, so the moment under the
    // pinch stays put instead of drifting toward the centre.
    private func zoomGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBaseWindow ?? (visibleStart, visibleEnd)
                if pinchBaseWindow == nil {
                    pinchBaseWindow = base
                    // A pinch beats an in-flight marker drag.
                    stopEdgeScroll()
                    dragTarget = nil
                    panBaseWindow = nil
                }
                let originalSpan = base.end - base.start
                let anchor = Double(value.startAnchor.x).clamped(to: 0...1)
                let anchorTime = base.start + originalSpan * anchor
                let minSpan = min(Self.minWindowSpan, fullDuration)
                let maxSpan = max(fullDuration, minSpan)
                let newSpan = (originalSpan / max(value.magnification, 0.01)).clamped(to: minSpan...maxSpan)
                let clamped = clampedWindow(
                    newStart: anchorTime - newSpan * anchor,
                    newEnd: anchorTime + newSpan * (1 - anchor)
                )
                visibleStart = clamped.start
                visibleEnd = clamped.end
            }
            .onEnded { _ in
                guard pinchBaseWindow != nil else { return }
                pinchBaseWindow = nil
                onWindowChanged(visibleStart...visibleEnd)
            }
    }

    /// Double tap: frame the current selection with a little air on either side.
    private func zoomToSelection() {
        let selection = max(trimEnd - trimStart, Self.minSelectionSpan)
        let minSpan = min(Self.minWindowSpan, fullDuration)
        let span = (selection * 1.3).clamped(to: minSpan...max(fullDuration, minSpan))
        let center = (trimStart + trimEnd) / 2
        let clamped = clampedWindow(newStart: center - span / 2, newEnd: center + span / 2)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            visibleStart = clamped.start
            visibleEnd = clamped.end
        }
        onWindowChanged(clamped.start...clamped.end)
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

    // MARK: - Coordinate mapping

    /// Horizontal position of a time within the live visible window.
    private func x(for time: Double, width: CGFloat) -> CGFloat {
        CGFloat((time - visibleStart) / visibleSpan) * width
    }

    /// Time at a horizontal position within the live visible window.
    private func time(forX x: CGFloat, width: CGFloat) -> Double {
        visibleStart + Double(x / max(width, 1)) * visibleSpan
    }

    // MARK: - Formatting

    private static func shortTime(_ time: Double) -> String {
        let total = Int(time.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func accessibilityTime(_ time: Double) -> String {
        Duration.seconds(max(time, 0)).formatted(.time(pattern: .minuteSecond))
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
