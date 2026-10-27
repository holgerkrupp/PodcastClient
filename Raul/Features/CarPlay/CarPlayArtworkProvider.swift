import CarPlay
import Foundation
import UIKit
import os

enum CarPlayArtworkSettings {
    static let showArtworkKey = "carPlayShowArtwork"
    static let didChange = Notification.Name("carPlayArtworkSettingDidChange")
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UpNext", category: "CarPlayArtwork")

    static var showArtwork: Bool {
        UserDefaults.standard.object(forKey: showArtworkKey) as? Bool ?? true
    }

    static func setShowArtwork(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: showArtworkKey)
        NotificationCenter.default.post(name: didChange, object: nil)
        logger.info("Artwork mode changed: \(enabled ? "enabled" : "text-only", privacy: .public)")
    }
}

enum CarPlayArtworkProvider {
    static let maximumConcurrentLoads = 4

    struct Request: Sendable {
        let index: Int
        let url: URL?
        let data: Data?
    }

    @MainActor
    static func pixelBudget(displayScale: CGFloat) -> CGFloat {
        let scale = max(1, displayScale)
        let maximumPoints = max(
            CPListItem.maximumImageSize.width,
            CPListItem.maximumImageSize.height
        )
        return min(512, max(32, ceil(maximumPoints * scale)))
    }

    nonisolated static func loadImage(
        from url: URL,
        maxPixelSize: CGFloat
    ) async -> UIImage? {
        guard CarPlayArtworkSettings.showArtwork else { return nil }
        let budget = max(1, min(Int(ceil(maxPixelSize)), 512))
        CarPlayArtworkSettings.logger.info("Artwork requested; source=remote budget=\(budget)")
        guard let image = await SharedImageRepository.shared.carPlayImage(for: url, maxPixelSize: budget),
              isDisplayable(image, maxPixelSize: budget) else {
            CarPlayArtworkSettings.logger.info("Artwork rejected or unavailable; source=remote")
            return nil
        }
        if let cgImage = image.cgImage {
            CarPlayArtworkSettings.logger.info("Artwork ready; source=remote size=\(cgImage.width)x\(cgImage.height) budget=\(budget)")
        }
        return image
    }

    nonisolated static func loadImage(
        from data: Data,
        maxPixelSize: CGFloat
    ) -> UIImage? {
        guard CarPlayArtworkSettings.showArtwork else { return nil }
        let budget = max(1, min(Int(ceil(maxPixelSize)), 512))
        CarPlayArtworkSettings.logger.info("Artwork requested; source=inline budget=\(budget)")
        guard let image = ImageLoaderAndCache.makeCarPlayUIImage(from: data, maxPixelSize: budget),
              isDisplayable(image, maxPixelSize: budget) else {
            CarPlayArtworkSettings.logger.info("Artwork rejected or unavailable; source=inline")
            return nil
        }
        if let cgImage = image.cgImage {
            CarPlayArtworkSettings.logger.info("Artwork ready; source=inline size=\(cgImage.width)x\(cgImage.height) budget=\(budget)")
        }
        return image
    }

    nonisolated static func isDisplayable(_ image: UIImage, maxPixelSize: Int = 512) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let budget = min(max(maxPixelSize, 1), 512)
        return cgImage.width > 0 && cgImage.height > 0
            && cgImage.width <= budget && cgImage.height <= budget
    }

    @MainActor
    static func buttonImage(systemName: String, displayScale: CGFloat) -> UIImage? {
        guard CarPlayArtworkSettings.showArtwork else { return nil }
        let scale = max(displayScale, 1)
        let maximum = Int(min(512, max(24, ceil(CPNowPlayingButtonMaximumImageSize.width * scale))))
        let config = UIImage.SymbolConfiguration(pointSize: CGFloat(maximum) / scale, weight: .regular)
        guard let symbol = UIImage(systemName: systemName, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: maximum, height: maximum), format: format)
        let bitmap = renderer.image { _ in
            let ratio = min(CGFloat(maximum) / max(symbol.size.width, 1), CGFloat(maximum) / max(symbol.size.height, 1))
            let size = CGSize(width: symbol.size.width * ratio, height: symbol.size.height * ratio)
            let rect = CGRect(
                x: (CGFloat(maximum) - size.width) / 2,
                y: (CGFloat(maximum) - size.height) / 2,
                width: size.width,
                height: size.height
            )
            symbol.draw(in: rect)
        }
        guard isDisplayable(bitmap, maxPixelSize: maximum) else { return nil }
        CarPlayArtworkSettings.logger.info("Artwork ready; source=button size=\(maximum)x\(maximum) budget=\(maximum)")
        return bitmap
    }

    @MainActor
    static func loadBounded(
        requests: [(index: Int, url: URL)],
        maxPixelSize: CGFloat,
        maximumConcurrentLoads: Int = maximumConcurrentLoads,
        loader: @escaping @Sendable (URL, CGFloat) async -> UIImage? = {
            await loadImage(from: $0, maxPixelSize: $1)
        },
        didLoad: @escaping @MainActor @Sendable (Int, UIImage) -> Void
    ) async {
        guard requests.isEmpty == false else { return }
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            var nextIndex = 0
            let initialCount = min(max(1, maximumConcurrentLoads), requests.count)
            for _ in 0..<initialCount {
                let request = requests[nextIndex]
                nextIndex += 1
                group.addTask {
                    (request.index, await loader(request.url, maxPixelSize))
                }
            }

            while let (index, image) = await group.next() {
                if Task.isCancelled {
                    CarPlayArtworkSettings.logger.info("Artwork batch cancelled")
                    group.cancelAll(); return
                }
                if let image, isDisplayable(image, maxPixelSize: Int(ceil(maxPixelSize))) {
                    didLoad(index, image)
                }
                guard nextIndex < requests.count else { continue }
                let request = requests[nextIndex]
                nextIndex += 1
                group.addTask {
                    (request.index, await loader(request.url, maxPixelSize))
                }
            }
        }
    }

    @MainActor
    static func loadBounded(
        requests: [Request],
        maxPixelSize: CGFloat,
        didLoad: @escaping @MainActor @Sendable (Int, UIImage) -> Void
    ) async {
        guard requests.isEmpty == false, CarPlayArtworkSettings.showArtwork else { return }
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            var nextIndex = 0
            func add(_ request: Request) {
                group.addTask {
                    if let data = request.data {
                        return (request.index, loadImage(from: data, maxPixelSize: maxPixelSize))
                    }
                    guard let url = request.url else { return (request.index, nil) }
                    return (request.index, await loadImage(from: url, maxPixelSize: maxPixelSize))
                }
            }
            for _ in 0..<min(maximumConcurrentLoads, requests.count) {
                add(requests[nextIndex]); nextIndex += 1
            }
            while let (index, image) = await group.next() {
                if Task.isCancelled || CarPlayArtworkSettings.showArtwork == false {
                    CarPlayArtworkSettings.logger.info("Artwork batch cancelled")
                    group.cancelAll(); return
                }
                if let image { didLoad(index, image) }
                if nextIndex < requests.count { add(requests[nextIndex]); nextIndex += 1 }
            }
        }
    }
}
