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
    

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Waveform
                HStack(spacing: 1) {
                    ForEach(samples.indices, id: \.self) { sampleIndex in
                        let sample = samples[sampleIndex]
                        Capsule()
                            .fill(Color.accent.opacity(0.7))
                            .frame(width: 2, height: max(2, CGFloat(sample) * geo.size.height))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                if trimEnd > trimStart, progress >= 0, progress <= (trimEnd - trimStart) {
                    let progressX = position(for: trimStart + progress, in: geo.size.width)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 3, height: geo.size.height)
                        .position(x: progressX, y: geo.size.height / 2)
                        .allowsHitTesting(true)
                        
                }
                
                // Trim overlays
                trimOverlay(color: Color.accent.opacity(0.2),
                            from: 0,
                            to: position(for: trimStart, in: geo.size.width))
              
                trimOverlay(color: Color.accent.opacity(0.2),
                            from: position(for: trimEnd, in: geo.size.width),
                            to: geo.size.width)
                // Trim handles
                trimHandle(x: position(for: trimStart, in: geo.size.width),
                           color: .accent,
                           systemName: "arrow.left",
                           onDrag: { x in
                               let percent = x / geo.size.width
                               let newTime = trimRange.lowerBound + (trimRange.upperBound-trimRange.lowerBound) * percent
                               onTrimStartChanged(newTime.clamped(to: trimRange.lowerBound...trimEnd))
                           })
                trimHandle(x: position(for: trimEnd, in: geo.size.width),
                           color: .accent,
                           systemName: "arrow.right",
                           onDrag: { x in
                               let percent = x / geo.size.width
                               let newTime = trimRange.lowerBound + (trimRange.upperBound-trimRange.lowerBound) * percent
                               onTrimEndChanged(newTime.clamped(to: trimStart...trimRange.upperBound))
                           })
            }
        }
        .frame(height: 60)
    }

    // Helper: position for a time value
    func position(for time: Double, in width: CGFloat) -> CGFloat {
        CGFloat((time - trimRange.lowerBound) / (trimRange.upperBound - trimRange.lowerBound)) * width
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
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return Array(repeating: 0.05, count: sampleCount) }
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
        // Downsample to sampleCount
        let stride = max(samples.count / sampleCount, 1)
        var downsampled: [Float] = []
        var i = 0
        while i < samples.count { downsampled.append(samples[i]); i += stride }
        while downsampled.count < sampleCount { downsampled.append(0.05) }
        if downsampled.count > sampleCount { downsampled = Array(downsampled.prefix(sampleCount)) }
        return downsampled
    }
}
