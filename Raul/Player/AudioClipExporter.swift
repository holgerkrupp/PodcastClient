import SwiftUI
import AVFoundation

enum AudioClipExporter {

    enum ExportError: Error {
        case failedToCreateWriter
        case failedToAppendFrame
        case taskCancelled
    }


     static func exportClipAsync(
        audioURL: URL,
        coverImage: UIImage,
        startTime: Double,
        endTime: Double,
        fps: Int,
        videoSize:CGSize? = CGSize(width: 720, height: 720),
      progress: @escaping @Sendable  (Double) -> Void) async throws -> URL {

        let frameCount = Int(Double(fps) * (endTime - startTime))
        let videoSize = CGSize(width: 720, height: 720) // square video
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        guard let videoWriter = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw ExportError.failedToCreateWriter
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: videoSize.width,
            kCVPixelBufferHeightKey as String: videoSize.height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                           sourcePixelBufferAttributes: pixelBufferAttributes)

        guard videoWriter.canAdd(videoInput) else {
            throw ExportError.failedToCreateWriter
        }
        videoWriter.add(videoInput)
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
           

            videoInput.requestMediaDataWhenReady(on: DispatchQueue.global(qos: .userInitiated)) {
                var currentFrame = 0
                while videoInput.isReadyForMoreMediaData && currentFrame < frameCount {
                    autoreleasepool {
                        let time = CMTime(seconds: Double(currentFrame) / Double(fps), preferredTimescale: 600)
                        guard let buffer = pixelBuffer(from: coverImage, size: videoSize) else {
                            continuation.resume(throwing: ExportError.failedToAppendFrame)
                            return
                        }
                        if !adaptor.append(buffer, withPresentationTime: time) {
                            continuation.resume(throwing: ExportError.failedToAppendFrame)
                            return
                        }
                        currentFrame += 1
                        progress(Double(currentFrame) / Double(frameCount))
                    }
                }

                if currentFrame >= frameCount {
                    videoInput.markAsFinished()
                    videoWriter.finishWriting {
                        if videoWriter.status == .completed {
                            continuation.resume(returning: outputURL)
                        } else {
                            continuation.resume(throwing: videoWriter.error ?? ExportError.failedToAppendFrame)
                        }
                    }
                }
            }
        }

        // Merge audio track
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        try await mergeAudio(from: audioURL, intoVideo: outputURL, startTime: startTime, endTime: endTime, outputURL: finalURL)
        try? FileManager.default.removeItem(at: outputURL)
        return finalURL
    }

    private static func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pxbuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width),
                                         Int(size.height),
                                         kCVPixelFormatType_32ARGB,
                                         attrs as CFDictionary,
                                         &pxbuffer)
        guard status == kCVReturnSuccess, let buffer = pxbuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                width: Int(size.width),
                                height: Int(size.height),
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard let ctx = context else { CVPixelBufferUnlockBaseAddress(buffer, []); return nil }

        ctx.clear(CGRect(origin: .zero, size: size))
        ctx.draw(image.cgImage!, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func mergeAudio(from audioURL: URL, intoVideo videoURL: URL, startTime: Double, endTime: Double, outputURL: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVAsset(url: videoURL)
        let audioAsset = AVAsset(url: audioURL)

        guard let videoTrack = videoAsset.tracks(withMediaType: .video).first,
              let videoCompTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.failedToCreateWriter
        }
        try videoCompTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoAsset.duration),
                                           of: videoTrack,
                                           at: .zero)

        if let audioTrack = audioAsset.tracks(withMediaType: .audio).first,
           let audioCompTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = CMTimeRange(start: CMTime(seconds: startTime, preferredTimescale: 600),
                                    end: CMTime(seconds: endTime, preferredTimescale: 600))
            try audioCompTrack.insertTimeRange(range, of: audioTrack, at: .zero)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.failedToCreateWriter
        }
        exporter.outputFileType = .mp4
        exporter.outputURL = outputURL
        try await withCheckedThrowingContinuation { cont in
            exporter.exportAsynchronously {
                if exporter.status == .completed {
                    cont.resume(returning: ())
                } else {
                    cont.resume(throwing: exporter.error ?? ExportError.failedToCreateWriter)
                }
            }
        }
    }
}
