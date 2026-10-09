import Foundation
import AVFoundation

enum AudioAnalysisSourceKind: String, Codable, Sendable {
    case downloadedFile
    case remoteFile
    case playerSampleBuffer
    case unsupported
}

struct PCMAnalysisChunk: Sendable, Equatable {
    let start: TimeInterval
    let duration: TimeInterval
    let sampleRate: Double
    let samples: [Float]
}

enum AudioAnalysisSourceError: LocalizedError, Sendable {
    case unsupported(String)
    case noAudioTrack
    case cannotRead(URL)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        case .noAudioTrack: return "The media has no readable audio track."
        case .cannotRead(let url): return "The audio analysis source could not read \(url.lastPathComponent)."
        }
    }
}

protocol AudioAnalysisSource: Sendable {
    var kind: AudioAnalysisSourceKind { get }
    func forEachChunk(
        in range: AdTimeRange,
        windowDuration: TimeInterval,
        hopDuration: TimeInterval,
        consume: (PCMAnalysisChunk) async throws -> Void
    ) async throws
}

enum AudioAnalysisSourceFactory {
    static func make(for url: URL) -> any AudioAnalysisSource {
        if url.pathExtension.lowercased() == "m3u8" {
            return UnsupportedAudioAnalysisSource(
                reason: "Playback sample-buffer analysis is not available for this stream on the current OS."
            )
        }
        return AVAudioFileAnalysisSource(url: url)
    }

#if !os(watchOS)
    static func make(for item: AVPlayerItem) -> any AudioAnalysisSource {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            return AVPlayerSampleBufferAnalysisSource(item: item)
        }
        return UnsupportedAudioAnalysisSource(
            reason: "Playback sample-buffer analysis requires the newer AVFoundation API."
        )
    }
#endif
}

struct UnsupportedAudioAnalysisSource: AudioAnalysisSource {
    let reason: String
    let kind: AudioAnalysisSourceKind = .unsupported

    func forEachChunk(
        in range: AdTimeRange,
        windowDuration: TimeInterval,
        hopDuration: TimeInterval,
        consume: (PCMAnalysisChunk) async throws -> Void
    ) async throws {
        throw AudioAnalysisSourceError.unsupported(reason)
    }
}

/// Reads decoded PCM from a local file, or downloads a remote MP3/M4A to the
/// app cache before reading it. The playback AVPlayer never touches this file
/// reader, so analysis seeking and speed changes cannot perturb playback.
struct AVAudioFileAnalysisSource: AudioAnalysisSource {
    let url: URL
    let kind: AudioAnalysisSourceKind

    init(url: URL) {
        self.url = url
        self.kind = url.isFileURL ? .downloadedFile : .remoteFile
    }

    func forEachChunk(
        in range: AdTimeRange,
        windowDuration: TimeInterval,
        hopDuration: TimeInterval,
        consume: (PCMAnalysisChunk) async throws -> Void
    ) async throws {
        let readableURL = try await AnalysisAssetCache.localURL(for: url)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: readableURL)
        } catch {
            throw AudioAnalysisSourceError.cannotRead(readableURL)
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate.isFinite,
              sampleRate > 0,
              format.channelCount > 0,
              format.channelCount <= 32 else {
            throw AudioAnalysisSourceError.noAudioTrack
        }

        let duration = Double(file.length) / sampleRate
        guard duration.isFinite else { throw AudioAnalysisSourceError.noAudioTrack }
        let requestedStart = range.start.isFinite ? max(range.start, 0) : 0
        let requestedEnd = range.end.flatMap { $0.isFinite ? $0 : nil } ?? duration
        let start = min(requestedStart, duration)
        let end = min(max(requestedEnd, start), duration)
        let window = windowDuration.isFinite ? min(max(windowDuration, 1), 300) : 30
        let requestedHop = hopDuration.isFinite ? hopDuration : window / 2
        let hop = max(min(requestedHop, window), 0.25)
        // A corrupt duration/sample-rate must never turn into an oversized
        // allocation. Analysis deliberately uses a modest maximum window.
        let maximumFrames = 30 * 48_000
        let requestedFrames = min(max(sampleRate * window, 1), Double(maximumFrames))
        let windowFrames = AVAudioFrameCount(requestedFrames)
        var offset = start

        while offset < end {
            try Task.checkCancellation()
            let availableFrameValue = min(
                max((end - offset) * sampleRate, 0).rounded(.up),
                Double(windowFrames)
            )
            let availableFrames = AVAudioFrameCount(availableFrameValue)
            let frameCount = min(windowFrames, max(availableFrames, 1))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { break }
            try Task.checkCancellation()
            file.framePosition = AVAudioFramePosition((offset * sampleRate).rounded())
            try file.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { break }

            let samples = Self.monoSamples(from: buffer)
            if samples.isEmpty == false {
                try await consume(PCMAnalysisChunk(
                        start: offset,
                        duration: Double(buffer.frameLength) / sampleRate,
                        sampleRate: sampleRate,
                        samples: samples
                    ))
            }
            offset += hop
        }
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }
        var result = Array(repeating: Float.zero, count: frameCount)

        if let channels = buffer.floatChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    result[frame] += channels[channel][frame] / Float(channelCount)
                }
            }
        } else if let channels = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    result[frame] += Float(channels[channel][frame]) / (Float(Int16.max) * Float(channelCount))
                }
            }
        } else if let channels = buffer.int32ChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    result[frame] += Float(channels[channel][frame]) / (Float(Int32.max) * Float(channelCount))
                }
            }
        }
        return result
    }
}

#if !os(watchOS)
/// iOS/macOS 27's HLS-only path. The output is attached to the existing item,
/// so it observes decoded samples without replacing or reconfiguring playback.
/// Its presentation timestamps are episode-time timestamps; ordinary MP3/M4A
/// uses `AVAudioFileAnalysisSource` above because Apple currently limits this
/// API to HLS.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, *)
final class AVPlayerSampleBufferAnalysisSource: @unchecked Sendable, AudioAnalysisSource {
    let kind: AudioAnalysisSourceKind = .playerSampleBuffer
    private let output: AVPlayerItemSampleBufferOutput

    init(item: AVPlayerItem) {
        output = AVPlayerItemSampleBufferOutput(configuration: nil)
        item.add(output)
    }

    func forEachChunk(
        in range: AdTimeRange,
        windowDuration: TimeInterval,
        hopDuration: TimeInterval,
        consume: (PCMAnalysisChunk) async throws -> Void
    ) async throws {
        while let sequence = await output.nextSampleBuffer() {
            try Task.checkCancellation()
            let sample = sequence.sampleBuffer
            let start = sample.presentationTimeStamp.seconds
            let duration = sample.duration.seconds
            guard start.isFinite, duration.isFinite, duration > 0 else { continue }
            guard start + duration >= range.start,
                  range.end.map({ start <= $0 }) ?? true else {
                if let end = range.end, start > end { break }
                continue
            }
            // SampleBufferOutput is the decoded PCM handoff. The chunk keeps
            // the stable timing metadata; providers that need raw frame values
            // can consume the output directly on OS 27 without copying through
            // the normal AVPlayer path.
            try await consume(PCMAnalysisChunk(
                    start: start,
                    duration: duration,
                    sampleRate: 0,
                    samples: []
                ))
            if let end = range.end, start >= end { break }
        }
    }
}
#endif

private enum AnalysisAssetCache {
    static func localURL(for url: URL) async throws -> URL {
        guard url.isFileURL == false else { return url }

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AdDetection/Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(url.absoluteString.utf8.reduce(into: UInt64(1469598103934665603)) { hash, byte in
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        })
        let destination = directory.appendingPathComponent(name + ".audio")
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        let (temporaryURL, _) = try await URLSession.shared.download(from: url)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }
}
