import SwiftUI
import AVFoundation
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
#endif

enum AudioClipExporter {

    enum ExportError: Error {
        case failedToCreateWriter
        case failedToAppendFrame
        case noPlayableMedia
        case taskCancelled
    }

    private final class UnsafeSendableBox<Value>: @unchecked Sendable {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private final class FrameWritingState: @unchecked Sendable {
        var currentFrame = 0
        var didComplete = false
    }

    // MARK: - Export Clip
    static func exportClipAsync(
        audioURL: URL,
        title: String? = nil,
        coverImage: UIImage,
        startTime: Double,
        endTime: Double,
        playbackRate: Float,
        fps: Int,
        videoSize: CGSize?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let sanitizedPlaybackRate = max(Double(playbackRate), 0.1)
        let clipDuration = max(endTime - startTime, 0)
        let outputDuration = clipDuration / sanitizedPlaybackRate
        let frameCount = max(Int(Double(fps) * outputDuration), 1)
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

        // Precompute static image template
        let template: UIImage
        if let cached = await PixelBufferCache.shared.template(for: coverImage, size: videoSize) {
            template = cached
        } else {
            template = coverImage
            await PixelBufferCache.shared.storeTemplate(template, for: videoSize)
        }




        // MARK: Write video frames
        let videoInputBox = UnsafeSendableBox(videoInput)
        let adaptorBox = UnsafeSendableBox(adaptor)
        let videoWriterBox = UnsafeSendableBox(videoWriter)
        let state = FrameWritingState()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            videoInputBox.value.requestMediaDataWhenReady(on: DispatchQueue.global(qos: .userInitiated)) {
                guard !state.didComplete else { return }

                while videoInputBox.value.isReadyForMoreMediaData && state.currentFrame < frameCount {
                    let appendSucceeded = autoreleasepool {
                        let frameProgress = Double(state.currentFrame) / Double(frameCount)
                        guard let buffer = createPixelBuffer(
                            from: template,
                            size: videoSize,
                            progress: frameProgress,
                            startTime: startTime,
                            endTime: endTime,
                            playbackRate: playbackRate,
                            title: title
                        ) else {
                            return false
                        }
                        let time = CMTime(seconds: Double(state.currentFrame) / Double(fps), preferredTimescale: 600)
                        guard adaptorBox.value.append(buffer, withPresentationTime: time) else {
                            return false
                        }
                        state.currentFrame += 1
                        progress(Double(state.currentFrame) / Double(frameCount))
                        return true
                    }

                    guard appendSucceeded else {
                        state.didComplete = true
                        videoInputBox.value.markAsFinished()
                        videoWriterBox.value.cancelWriting()
                        continuation.resume(throwing: ExportError.failedToAppendFrame)
                        return
                    }
                }

                guard state.currentFrame >= frameCount else {
                    return
                }

                state.didComplete = true
                videoInputBox.value.markAsFinished()
                videoWriterBox.value.finishWriting {
                    if videoWriterBox.value.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: videoWriterBox.value.error ?? ExportError.failedToAppendFrame)
                    }
                }
            }
        }

        // MARK: Merge audio track
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        try await mergeAudio(
            from: audioURL,
            intoVideo: outputURL,
            startTime: startTime,
            endTime: endTime,
            playbackRate: playbackRate,
            outputURL: finalURL
        )
        try? FileManager.default.removeItem(at: outputURL)
        return finalURL
    }

    static func exportVideoClipAsync(
        videoURL: URL,
        startTime: Double,
        endTime: Double,
        playbackRate: Float,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        progress(0.05)

        let asset = AVURLAsset(url: videoURL)
        let composition = AVMutableComposition()
        let sanitizedPlaybackRate = max(Double(playbackRate), 0.1)
        let start = CMTime(seconds: max(0, startTime), preferredTimescale: 600)
        let end = CMTime(seconds: max(startTime, endTime), preferredTimescale: 600)
        let timeRange = CMTimeRange(start: start, end: end)
        let scaledDuration = CMTime(
            seconds: timeRange.duration.seconds / sanitizedPlaybackRate,
            preferredTimescale: 600
        )

        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ExportError.noPlayableMedia
        }

        try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
        compositionVideoTrack.scaleTimeRange(
            CMTimeRange(start: .zero, duration: timeRange.duration),
            toDuration: scaledDuration
        )
        compositionVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        progress(0.35)

        if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
            compositionAudioTrack.scaleTimeRange(
                CMTimeRange(start: .zero, duration: timeRange.duration),
                toDuration: scaledDuration
            )
        }
        progress(0.55)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.failedToCreateWriter
        }

        progress(0.75)
        try await exporter.export(to: outputURL, as: .mp4)
        progress(1.0)

        return outputURL
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
    static func createPixelBuffer(
        from image: UIImage,
        size: CGSize,
        progress: Double,
        startTime: Double,
        endTime: Double,
        playbackRate: Float = 1.0,
        title: String? = nil
    ) -> CVPixelBuffer? {
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
        guard let imageCGImage = image.cgImage else {
            return nil
        }

        let ciImage = CIImage(cgImage: imageCGImage)
        if let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(80, forKey: kCIInputRadiusKey)
            if let output = filter.outputImage,
               let cgBlurred = sharedCIContext.createCGImage(output, from: ciImage.extent) {
                let overscan: CGFloat = 1.2
                // Aspect-fill calculation
                let imageAspect = ciImage.extent.width / ciImage.extent.height
                let canvasAspect = size.width / size.height
                var drawRect = CGRect.zero
                if imageAspect > canvasAspect {
                    // Image is wider: fill height, crop sides
                    let scale = size.height / ciImage.extent.height * overscan
                    let scaledWidth = ciImage.extent.width * scale * overscan
                    drawRect = CGRect(
                        x: (size.width - scaledWidth) / 2,
                        y: 0,
                        width: scaledWidth,
                        height: size.height
                    )
                } else {
                    // Image is taller: fill width, crop top/bottom
                    let scale = size.width / ciImage.extent.width * overscan
                    let scaledHeight = ciImage.extent.height * scale * overscan
                    drawRect = CGRect(
                        x: 0,
                        y: (size.height - scaledHeight) / 2,
                        width: size.width,
                        height: scaledHeight
                    )
                }
                context.draw(cgBlurred, in: drawRect)
            }
        }


        
        // Adjusted positioning for progress bar and time labels near bottom
        let bottomMargin: CGFloat = 12.0
        let barMargin: CGFloat = 24.0
        let barHeight: CGFloat = 16.0
        let timeFontSize: CGFloat = 20.0
        let titleFontSize: CGFloat = 30.0
        let timeLabelHeight = timeFontSize + 2 // Estimate, since font is 20pt, add a bit more for line height
        let gap: CGFloat = 0.0

        let textY = 0  + bottomMargin
        let barWidth = size.width - 2 * barMargin
        let barY = textY + timeLabelHeight + gap + barHeight
        let capsuleRect = CGRect(x: barMargin, y: barY, width: barWidth, height: barHeight)

        // Draw progress bar as a capsule
        let capsulePath = CGPath(
            roundedRect: capsuleRect,
            cornerWidth: barHeight / 2,
            cornerHeight: barHeight / 2,
            transform: nil
        )
        context.setFillColor(platformWhite(alpha: 0.22))
        context.addPath(capsulePath)
        context.fillPath()
        // Fill progress
        let progressWidth = barWidth * CGFloat(max(0, min(1, progress)))
        let progressRect = CGRect(x: barMargin, y: barY, width: progressWidth, height: barHeight)
        let progressCapsule = CGPath(
            roundedRect: progressRect,
            cornerWidth: barHeight / 2,
            cornerHeight: barHeight / 2,
            transform: nil
        )
        context.setFillColor(platformAccentColor())
        context.addPath(progressCapsule)
        context.fillPath()

        // Draw start and end time below bar using UIGraphicsImageRenderer for text + shadow
        let startString = Duration.seconds(startTime).formatted(.units(width: .narrow))
        let remainingDuration = ((endTime - startTime) * (1 - progress)) / max(Double(playbackRate), 0.1)
        let endString = Duration.seconds(remainingDuration).formatted(.units(width: .narrow))
        let monoFont = platformMonospacedFont(ofSize: timeFontSize, weight: .semibold)
        let fontattrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: platformWhiteObject
        ]
        
        var lowerImageBorder = barY + barHeight
        
        // Draw title text if available
        if let title {
            let titleLowerGap: CGFloat = 8.0
            let titleTextY = barY + barHeight + titleLowerGap
            
            let Font = platformSystemFont(ofSize: titleFontSize, weight: .semibold)
            let tittleFontattrs: [NSAttributedString.Key: Any] = [
                .font: Font,
                .foregroundColor: platformWhiteObject
            ]
            let titleImage = renderTextImage(title, attributes: tittleFontattrs)
            if let titleCGImage = titleImage.cgImage {
                context.draw(
                    titleCGImage,
                    in: CGRect(x: barMargin, y: titleTextY, width: titleImage.size.width, height: titleImage.size.height)
                )
            }

            
            lowerImageBorder += titleLowerGap + titleImage.size.height
        }
        let startImage = renderTextImage(startString, attributes: fontattrs)
        let endImage = renderTextImage(endString, attributes: fontattrs)
        if let startCGImage = startImage.cgImage {
            context.draw(
                startCGImage,
                in: CGRect(x: barMargin, y: textY, width: startImage.size.width, height: startImage.size.height)
            )
        }
        if let endCGImage = endImage.cgImage {
            context.draw(
                endCGImage,
                in: CGRect(x: size.width - barMargin - endImage.size.width, y: textY, width: endImage.size.width, height: endImage.size.height)
            )
        }
         
         
         
         // Draw foreground image (aspect fit)
         let aspectWidth = size.width / image.size.width
         let aspectHeight = size.height / image.size.height
         let scale = min(aspectWidth, aspectHeight) * 0.8
         let newWidth = image.size.width * scale
         let newHeight = image.size.height * scale
            let upperGap = 8.0
         let x = (size.width - newWidth) / 2
         let y = max(lowerImageBorder, (size.height - newHeight) / 2) + upperGap
         
       //  let y = ((size.height - newHeight) / 2) + (barY + barHeight + gapToBar)
         context.draw(imageCGImage, in: CGRect(x: x, y: y, width: newWidth, height: newHeight))

        return buffer
    }


    // MARK: - Merge audio into video
    private static func mergeAudio(
        from audioURL: URL,
        intoVideo videoURL: URL,
        startTime: Double,
        endTime: Double,
        playbackRate: Float,
        outputURL: URL
    ) async throws {
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
            let scaledDuration = CMTime(
                seconds: range.duration.seconds / max(Double(playbackRate), 0.1),
                preferredTimescale: 600
            )
            audioCompTrack.scaleTimeRange(
                CMTimeRange(start: .zero, duration: range.duration),
                toDuration: scaledDuration
            )
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.failedToCreateWriter
        }
        try await exporter.export(to: outputURL, as: .mp4)
    }
}

private extension AudioClipExporter {
    static func renderTextImage(_ text: String, attributes: [NSAttributedString.Key: Any]) -> UIImage {
        let measuredSize = (text as NSString).size(withAttributes: attributes)
        let textSize = CGSize(width: ceil(measuredSize.width), height: ceil(measuredSize.height))

#if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: textSize)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.setShadow(
                offset: CGSize(width: 1, height: 1),
                blur: 4,
                color: UIColor.black.withAlphaComponent(0.85).cgColor
            )
            (text as NSString).draw(at: .zero, withAttributes: attributes)
        }
#else
        let image = NSImage(size: textSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return UIImage()
        }

        context.setShadow(
            offset: CGSize(width: 1, height: 1),
            blur: 4,
            color: NSColor.black.withAlphaComponent(0.85).cgColor
        )
        (text as NSString).draw(at: .zero, withAttributes: attributes)

        guard let tiffData = image.tiffRepresentation,
              let imageRep = NSBitmapImageRep(data: tiffData),
              let cgImage = imageRep.cgImage else {
            return UIImage()
        }

        return UIImage(cgImage: cgImage)
#endif
    }

#if canImport(UIKit)
    static let platformWhiteObject = UIColor.white

    static func platformWhite(alpha: CGFloat) -> CGColor {
        UIColor(white: 1.0, alpha: alpha).cgColor
    }

    static func platformAccentColor() -> CGColor {
        UIColor.systemBlue.cgColor
    }

    static func platformMonospacedFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func platformSystemFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight)
    }
#else
    static let platformWhiteObject = NSColor.white

    static func platformWhite(alpha: CGFloat) -> CGColor {
        NSColor.white.withAlphaComponent(alpha).cgColor
    }

    static func platformAccentColor() -> CGColor {
        NSColor.controlAccentColor.cgColor ?? NSColor.systemBlue.cgColor
    }

    static func platformMonospacedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func platformSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
#endif
}
