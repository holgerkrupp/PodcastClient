import SwiftUI
import AVFoundation
import Synchronization
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
#endif

enum AudioClipExporter {

    /// Keeps caption windows consistent between the live preview and export.
    /// Widescreen clips use the 16:9 line width; other ratios use the wider
    /// 4:3 allowance.
    static func captionWindow(_ caption: ClipCaptionTimeline.Caption, canvasSize: CGSize) -> ClipCaptionTimeline.Caption {
        let fontSize = max(18, min(canvasSize.width * 0.045, 40))
        let maxWidth = max(1, canvasSize.width * captionWidthRatio(for: canvasSize))
        let charactersPerLine = max(12, Int(maxWidth / (fontSize * 0.54)))
        let speakerLength = caption.speaker?.utf16.count ?? 0
        return caption.contextualized(maximumUTF16Length: max(12, charactersPerLine * 2 - speakerLength))
    }

    static func captionWidthRatio(for canvasSize: CGSize) -> CGFloat {
        let aspectRatio = canvasSize.width / max(canvasSize.height, 1)
        return abs(aspectRatio - (16.0 / 9.0)) < 0.08 ? 0.68 : 0.90
    }

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
        private struct CompletionState {
            var continuation: CheckedContinuation<Void, Error>?
            var didComplete = false
        }

        private let completionState = Mutex(CompletionState())

        // These are accessed exclusively on the serial writer queue below.
        var currentFrame = 0
        var isFinishing = false
        var lastCaption: ClipCaptionTimeline.Caption?
        var lastCaptionImage: UIImage?

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            completionState.withLock { state in
                state.continuation = continuation
            }
        }

        func isCompleted() -> Bool {
            completionState.withLock { $0.didComplete }
        }

        func complete(_ result: Result<Void, Error>) {
            let continuation: CheckedContinuation<Void, Error>? = completionState.withLock { state in
                guard state.didComplete == false else { return nil }
                state.didComplete = true
                defer { state.continuation = nil }
                return state.continuation
            }
            guard let continuation else { return }

            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
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
        captionTimeline: ClipCaptionTimeline? = nil,
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
        let writerQueue = DispatchQueue(
            label: "AudioClipExporter.FrameWriter",
            qos: .userInitiated
        )

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.install(continuation)
                videoInputBox.value.requestMediaDataWhenReady(on: writerQueue) {
                    guard state.isCompleted() == false, state.isFinishing == false else { return }

                    while videoInputBox.value.isReadyForMoreMediaData && state.currentFrame < frameCount {
                        let appendSucceeded = autoreleasepool {
                            let frameProgress = Double(state.currentFrame) / Double(frameCount)
                            let caption = captionTimeline?.caption(atMediaTime: startTime + Double(state.currentFrame) / Double(fps) * sanitizedPlaybackRate)
                            if caption != state.lastCaption {
                                state.lastCaption = caption
                                state.lastCaptionImage = caption.flatMap { renderCaptionImage($0, canvasSize: videoSize) }
                            }
                            guard let buffer = createPixelBuffer(
                                from: template,
                                size: videoSize,
                                progress: frameProgress,
                                startTime: startTime,
                                endTime: endTime,
                                playbackRate: playbackRate,
                                title: title,
                                caption: caption,
                                renderedCaption: state.lastCaptionImage
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
                            videoInputBox.value.markAsFinished()
                            videoWriterBox.value.cancelWriting()
                            state.complete(.failure(ExportError.failedToAppendFrame))
                            return
                        }
                    }

                    guard state.currentFrame >= frameCount else {
                        return
                    }

                    state.isFinishing = true
                    videoInputBox.value.markAsFinished()
                    videoWriterBox.value.finishWriting {
                        if videoWriterBox.value.status == .completed {
                            state.complete(.success(()))
                        } else {
                            state.complete(.failure(videoWriterBox.value.error ?? ExportError.failedToAppendFrame))
                        }
                    }
                }
            }
        }, onCancel: {
            writerQueue.async {
                guard state.isCompleted() == false else { return }
                videoInputBox.value.markAsFinished()
                videoWriterBox.value.cancelWriting()
                state.complete(.failure(ExportError.taskCancelled))
            }
        })

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
        captionTimeline: ClipCaptionTimeline? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        progress(0.05)

        let protectedVideoURL = videoURL.isFileURL
            ? videoURL
            : try PodcastNetworkPrivacyPolicy.wireURL(for: videoURL, purpose: .audio)
        let asset = AVURLAsset(
            url: protectedVideoURL,
            options: ["AVURLAssetHTTPUserAgentKey": "UpNext/1.0"]
        )
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
        let sourceTransform = try await sourceVideoTrack.load(.preferredTransform)
        compositionVideoTrack.preferredTransform = sourceTransform
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

        if let captionTimeline {
            let sourceSize = try await sourceVideoTrack.load(.naturalSize)
            let captions = captionTimeline.clipped(start: startTime, end: endTime, playbackRate: sanitizedPlaybackRate)
            exporter.videoComposition = try await makeCaptionVideoComposition(
                asset: composition, sourceSize: sourceSize, sourceTransform: sourceTransform, captions: captions
            )
            exporter.timeRange = CMTimeRange(start: .zero, duration: scaledDuration)
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
        title: String? = nil,
        caption: ClipCaptionTimeline.Caption? = nil,
        renderedCaption: UIImage? = nil
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

        if let caption, let image = renderedCaption ?? renderCaptionImage(caption, canvasSize: size), let cgImage = image.cgImage {
            let width = min(image.size.width, size.width - 32)
            let height = min(image.size.height, size.height * 0.25)
            context.draw(cgImage, in: CGRect(x: (size.width - width) / 2,
                                              y: (size.height - height) / 2,
                                              width: width, height: height))
        }

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
        let protectedVideoURL = videoURL.isFileURL
            ? videoURL
            : try PodcastNetworkPrivacyPolicy.wireURL(for: videoURL, purpose: .audio)
        let protectedAudioURL = audioURL.isFileURL
            ? audioURL
            : try PodcastNetworkPrivacyPolicy.wireURL(for: audioURL, purpose: .audio)
        let options = ["AVURLAssetHTTPUserAgentKey": "UpNext/1.0"]
        let videoAsset = AVURLAsset(url: protectedVideoURL, options: options)
        let audioAsset = AVURLAsset(url: protectedAudioURL, options: options)

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
    static func makeCaptionVideoComposition(
        asset: AVAsset, sourceSize: CGSize, sourceTransform: CGAffineTransform, captions: ClipCaptionTimeline
    ) async throws -> AVVideoComposition {
        let bounds = CGRect(origin: .zero, size: sourceSize).applying(sourceTransform).standardized
        let renderSize = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        // Render caption images once; the frame callback only selects and composites.
        let images = UnsafeSendableBox(captions.captions.compactMap { caption -> (ClipCaptionTimeline.Caption, CIImage)? in
            guard let image = renderCaptionImage(caption, canvasSize: renderSize), let cgImage = image.cgImage else { return nil }
            return (caption, CIImage(cgImage: cgImage))
        })
        return try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
            let source = parameters.sourceImage
            guard let caption = captions.caption(atMediaTime: parameters.compositionTime.seconds),
                  let image = images.value.first(where: { $0.0 == caption })?.1 else {
                return AVCIImageFilteringResult(resultImage: source)
            }
            let extent = source.extent
            let translated = image.transformed(by: CGAffineTransform(
                translationX: extent.midX - image.extent.width / 2,
                y: extent.midY - image.extent.height / 2
            ))
            return AVCIImageFilteringResult(resultImage: translated.composited(over: source).cropped(to: extent))
        }
    }

    static func renderCaptionImage(_ caption: ClipCaptionTimeline.Caption, canvasSize: CGSize) -> UIImage? {
        let display = captionWindow(caption, canvasSize: canvasSize)
        guard display.location >= 0, display.length > 0,
              display.location <= display.text.utf16.count,
              display.length <= display.text.utf16.count - display.location,
              Range(NSRange(location: display.location, length: display.length), in: display.text) != nil else { return nil }
        let fontSize = max(18, min(canvasSize.width * 0.045, 40))
        let value = NSMutableAttributedString()
        if let speaker = display.speaker, speaker.isEmpty == false {
            value.append(NSAttributedString(
                string: "\(speaker):\n",
                attributes: [
                    .font: platformSystemFont(ofSize: fontSize * 0.82, weight: .semibold),
                    .foregroundColor: platformSpeakerColorObject
                ]
            ))
        }
        let bodyStart = value.length
        value.append(NSAttributedString(
            string: display.text,
            attributes: [
                .font: platformSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: platformWhiteObject
            ]
        ))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
        value.addAttributes([
            .font: platformSystemFont(ofSize: fontSize, weight: .bold),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ], range: NSRange(location: bodyStart + display.location, length: display.length))
        let widthRatio = captionWidthRatio(for: canvasSize)
        let maxWidth = max(1, canvasSize.width * widthRatio)
        let maxHeight = fontSize * 3.6
        let bounds = value.boundingRect(
            with: CGSize(width: maxWidth - 24, height: maxHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil
        )
        let imageSize = CGSize(width: min(maxWidth, ceil(bounds.width) + 24),
                               height: min(maxHeight, ceil(bounds.height)) + 16)
#if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
        return renderer.image { _ in
            let roundedRect = UIBezierPath(roundedRect: CGRect(origin: .zero, size: imageSize), cornerRadius: 16)
            UIColor.white.withAlphaComponent(0.10).setFill()
            roundedRect.fill()
            UIColor.black.withAlphaComponent(0.38).setFill()
            roundedRect.fill()
            UIColor.white.withAlphaComponent(0.22).setStroke()
            roundedRect.lineWidth = 1
            roundedRect.stroke()
            value.draw(with: CGRect(x: 12, y: 8, width: imageSize.width - 24, height: imageSize.height - 16),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
#else
        let image = NSImage(size: imageSize)
        image.lockFocus()
        let roundedRect = NSBezierPath(roundedRect: CGRect(origin: .zero, size: imageSize), xRadius: 16, yRadius: 16)
        NSColor.white.withAlphaComponent(0.10).setFill()
        roundedRect.fill()
        NSColor.black.withAlphaComponent(0.38).setFill()
        roundedRect.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        roundedRect.lineWidth = 1
        roundedRect.stroke()
        value.draw(with: CGRect(x: 12, y: 8, width: imageSize.width - 24, height: imageSize.height - 16),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        image.unlockFocus()
        guard let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data), let cgImage = rep.cgImage else { return nil }
        return UIImage(cgImage: cgImage)
#endif
    }

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
    static let platformSpeakerColorObject = UIColor.systemGreen

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
    static let platformSpeakerColorObject = NSColor.systemGreen

    static func platformWhite(alpha: CGFloat) -> CGColor {
        NSColor.white.withAlphaComponent(alpha).cgColor
    }

    static func platformAccentColor() -> CGColor {
        NSColor.controlAccentColor.cgColor
    }

    static func platformMonospacedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func platformSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
#endif
}
