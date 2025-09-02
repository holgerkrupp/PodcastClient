import SwiftUI
import AVFoundation

enum AudioClipExporter {

    enum ExportError: Error {
        case failedToCreateWriter
        case failedToAppendFrame
        case taskCancelled
    }

    // MARK: - Export Clip
    static func exportClipAsync(
        audioURL: URL,
        coverImage: UIImage,
        startTime: Double,
        endTime: Double,
        fps: Int,
        videoSize: CGSize?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {

        let frameCount = Int(Double(fps) * (endTime - startTime))
        let videoSize = videoSize ?? CGSize(width: 720, height: 720)
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

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard videoWriter.canAdd(videoInput) else {
            throw ExportError.failedToCreateWriter
        }

        videoWriter.add(videoInput)
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)

        // MARK: Precompute pixel buffer once
        let buffer: CVPixelBuffer
        // Precompute static image template
        let template: UIImage
        if let cached = await PixelBufferCache.shared.template(for: coverImage, size: videoSize) {
            template = cached
        } else {
            template = coverImage
            await PixelBufferCache.shared.storeTemplate(template, for: videoSize)
        }




        // MARK: Write video frames
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            videoInput.requestMediaDataWhenReady(on: DispatchQueue.global(qos: .userInitiated)) {
                var currentFrame = 0
                while videoInput.isReadyForMoreMediaData && currentFrame < frameCount {
                    autoreleasepool {
                        guard let buffer = createPixelBuffer(from: template, size: videoSize) else { return }
                        let time = CMTime(seconds: Double(currentFrame) / Double(fps), preferredTimescale: 600)
                        if !adaptor.append(buffer, withPresentationTime: time) {
                            continuation.resume(throwing: ExportError.failedToAppendFrame)
                            return
                        }
                        currentFrame += 1
                        progress(Double(currentFrame) / Double(frameCount))
                    }
                }
            

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

        // MARK: Merge audio track
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        try await mergeAudio(from: audioURL, intoVideo: outputURL, startTime: startTime, endTime: endTime, outputURL: finalURL)
        try? FileManager.default.removeItem(at: outputURL)
        return finalURL
    }

    // MARK: - Shared CIContext for Blur
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Actor Cache
    actor PixelBufferCache {
        static let shared = PixelBufferCache()
        
        private var cache: [String: UIImage] = [:] // Store the UIImage, not CVPixelBuffer
        
        func storeTemplate(_ image: UIImage, for size: CGSize) {
            let key = "\(Unmanaged.passUnretained(image).toOpaque())-\(Int(size.width))x\(Int(size.height))"
            cache[key] = image
        }
        
        func template(for image: UIImage, size: CGSize) -> UIImage? {
            let key = "\(Unmanaged.passUnretained(image).toOpaque())-\(Int(size.width))x\(Int(size.height))"
            return cache[key]
        }
    }


    // MARK: - Create CVPixelBuffer with blurred background + aspect-fit foreground
    private static func createPixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
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
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: Int(size.width),
                                      height: Int(size.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }

        context.clear(CGRect(origin: .zero, size: size))
        
        // Draw blurred background
        if let ciImage = CIImage(image: image),
           let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(20, forKey: kCIInputRadiusKey)
            if let output = filter.outputImage,
               let cgBlurred = sharedCIContext.createCGImage(output, from: ciImage.extent) {
                context.draw(cgBlurred, in: CGRect(origin: .zero, size: size))
            }
        }

        // Draw foreground image (aspect fit)
        let aspectWidth = size.width / image.size.width
        let aspectHeight = size.height / image.size.height
        let scale = min(aspectWidth, aspectHeight)
        let newWidth = image.size.width * scale
        let newHeight = image.size.height * scale
        let x = (size.width - newWidth) / 2
        let y = (size.height - newHeight) / 2
        context.draw(image.cgImage!, in: CGRect(x: x, y: y, width: newWidth, height: newHeight))

        return buffer
    }


    // MARK: - Merge audio into video
    private static func mergeAudio(from audioURL: URL, intoVideo videoURL: URL, startTime: Double, endTime: Double, outputURL: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        guard let videoTrack = try? await videoAsset.loadTracks(withMediaType: .video).first,
              let videoCompTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.failedToCreateWriter
        }
        try await videoCompTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoAsset.load(.duration)),
                                                 of: videoTrack,
                                                 at: .zero)

        if let audioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first,
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
