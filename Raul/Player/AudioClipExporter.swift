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
                        let frameProgress = Double(currentFrame) / Double(frameCount)
                        guard let buffer = createPixelBuffer(from: template, size: videoSize, progress: frameProgress, startTime: startTime, endTime: endTime) else { return }
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


    // MARK: - Create CVPixelBuffer with blurred background + aspect-fit foreground + progress bar
     static func createPixelBuffer(from image: UIImage, size: CGSize, progress: Double, startTime: Double, endTime: Double) -> CVPixelBuffer? {
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
            filter.setValue(80, forKey: kCIInputRadiusKey)
            if let output = filter.outputImage,
               let cgBlurred = sharedCIContext.createCGImage(output, from: ciImage.extent) {
                context.draw(cgBlurred, in: CGRect(origin: .zero, size: size))
            }
        }

        // Draw foreground image (aspect fit)
        let aspectWidth = size.width / image.size.width
        let aspectHeight = size.height / image.size.height
        let scale = min(aspectWidth, aspectHeight) * 0.8
        let newWidth = image.size.width * scale
        let newHeight = image.size.height * scale
        let x = (size.width - newWidth) / 2
        let y = (size.height - newHeight) / 2
        context.draw(image.cgImage!, in: CGRect(x: x, y: y, width: newWidth, height: newHeight))
        
        // Adjusted positioning for progress bar and time labels near bottom
        let bottomMargin: CGFloat = 12.0
        let barMargin: CGFloat = 24.0
        let barHeight: CGFloat = 16.0
        let timeFontSize: CGFloat = 20.0
        let timeLabelHeight = timeFontSize + 2 // Estimate, since font is 20pt, add a bit more for line height
        let gap: CGFloat = 0.0

        let textY = 0  + bottomMargin
        let barWidth = size.width - 2 * barMargin
        let barY = textY + timeLabelHeight + gap + barHeight
        let capsuleRect = CGRect(x: barMargin, y: barY, width: barWidth, height: barHeight)

        // Draw progress bar as a capsule
        let capsulePath = UIBezierPath(roundedRect: capsuleRect, cornerRadius: barHeight/2).cgPath
        context.setFillColor(UIColor(white: 1.0, alpha: 0.22).cgColor)
        context.addPath(capsulePath)
        context.fillPath()
        // Fill progress
        let progressWidth = barWidth * CGFloat(max(0, min(1, progress)))
        let progressRect = CGRect(x: barMargin, y: barY, width: progressWidth, height: barHeight)
        let progressCapsule = UIBezierPath(roundedRect: progressRect, cornerRadius: barHeight/2).cgPath
        context.setFillColor(UIColor.accent.cgColor)
        context.addPath(progressCapsule)
        context.fillPath()

        // Draw start and end time below bar using UIGraphicsImageRenderer for text + shadow
        let startString = Duration.seconds(startTime).formatted(.units(width: .narrow))
        let endString = Duration.seconds((endTime-startTime)*(1-progress)).formatted(.units(width: .narrow))
        let monoFont = UIFont.monospacedSystemFont(ofSize: timeFontSize, weight: .semibold)
        let fontattrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: UIColor.white
        ]

        func renderTextImage(_ text: String, attributes: [NSAttributedString.Key: Any]) -> UIImage {
            let textSize = (text as NSString).size(withAttributes: attributes)
            let renderer = UIGraphicsImageRenderer(size: textSize)
            return renderer.image { ctx in
                // Draw shadow
                let context = ctx.cgContext
                context.setShadow(offset: CGSize(width: 1, height: 1), blur: 4, color: UIColor.black.withAlphaComponent(0.85).cgColor)
                (text as NSString).draw(at: .zero, withAttributes: attributes)
            }
        }
        let startImage = renderTextImage(startString, attributes: fontattrs)
        let endImage = renderTextImage(endString, attributes: fontattrs)
        context.draw(startImage.cgImage!, in: CGRect(x: barMargin, y: textY, width: startImage.size.width, height: startImage.size.height))
        context.draw(endImage.cgImage!, in: CGRect(x: size.width - barMargin - endImage.size.width, y: textY, width: endImage.size.width, height: endImage.size.height))

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

