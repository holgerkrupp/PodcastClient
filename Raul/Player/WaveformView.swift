import SwiftUI
import AVFoundation

/// A view that draws the waveform for a segment of audio.
struct WaveformView: View {
    let samples: [Float]          // Normalized audio samples in 0...1
    let trimRange: ClosedRange<Double>
    let duration: Double
    let trimStart: Double
    let trimEnd: Double
    let onTrimStartChanged: (Double) -> Void
    let onTrimEndChanged: (Double) -> Void
    @Binding var progress: Double
    
    // How far inside (in seconds) the handles/overlays should start/end from the waveform edges.
    // Default to 10 seconds as requested.
    var insetSeconds: Double = 0.0

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 0.1
            let capsuleWidth = (geo.size.width - spacing * CGFloat(max(samples.count - 1, 0))) / CGFloat(samples.count)
            
            // Time span shown
            let totalTime = trimRange.upperBound - trimRange.lowerBound
            // Prevent division by zero
            let safeTotalTime = max(totalTime, 0.0001)
            // Convert inset seconds to pixels, but clamp so we never exceed half width
            let secondsPerPixel = safeTotalTime / geo.size.width
            let rawInsetPixels = CGFloat(insetSeconds / max(secondsPerPixel, 0.0001))
            let insetPixels = min(rawInsetPixels, geo.size.width * 0.45) // keep at least 10% usable width
            let effectiveWidth = max(geo.size.width - 2 * insetPixels, 1)
            
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
                        let newTime = trimRange.lowerBound + (safeTotalTime * percent)
                        onTrimStartChanged(newTime.clamped(to: trimRange.lowerBound...trimEnd))
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
                        let newTime = trimRange.lowerBound + (safeTotalTime * percent)
                        onTrimEndChanged(newTime.clamped(to: trimStart...trimRange.upperBound))
                    }
                )
            }
        }
        .frame(height: 60)
    }

    // Helper: position for a time value with inset-aware mapping
    func position(for time: Double, in width: CGFloat, inset: CGFloat, effectiveWidth: CGFloat) -> CGFloat {
        let total = max(trimRange.upperBound - trimRange.lowerBound, 0.0001)
        let percent = CGFloat((time - trimRange.lowerBound) / total)
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
            .gesture(
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
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return Array(repeating: 0.05, count: sampleCount) }
        let assetReader = try? AVAssetReader(asset: asset)
        let timeRange = CMTimeRange(start: .init(seconds: range.lowerBound, preferredTimescale: 600), duration: .init(seconds: range.upperBound-range.lowerBound, preferredTimescale: 600))
        assetReader?.timeRange = timeRange
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16
        ])
        assetReader?.add(output)
        var samples: [Float] = []
        assetReader?.startReading()
        while let buffer = output.copyNextSampleBuffer(), CMSampleBufferIsValid(buffer) {
            if let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
                }
                let sampleCount = length/2
                let int16Samples = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Int16] in
                    let bufferPointer = ptr.bindMemory(to: Int16.self)
                    return Array(bufferPointer)
                }
                let floats = int16Samples.map { abs(Float($0)) / Float(Int16.max) }
                samples.append(contentsOf: floats)
            }
        }
        assetReader?.cancelReading()
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
