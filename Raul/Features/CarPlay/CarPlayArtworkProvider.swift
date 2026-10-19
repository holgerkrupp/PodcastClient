import CarPlay
import Foundation
import UIKit

enum CarPlayArtworkProvider {
    static let maximumConcurrentLoads = 4

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
        guard let image = await ImageLoaderAndCache.loadUIImage(
            from: url,
            maxPixelSize: maxPixelSize
        ), isDisplayable(image) else {
            return nil
        }
        return image
    }

    nonisolated static func loadImage(
        from data: Data,
        maxPixelSize: CGFloat
    ) -> UIImage? {
        guard let image = ImageLoaderAndCache.makeUIImage(
            from: data,
            maxPixelSize: maxPixelSize
        ), isDisplayable(image) else {
            return nil
        }
        return image
    }

    nonisolated static func isDisplayable(_ image: UIImage) -> Bool {
        if let cgImage = image.cgImage {
            return cgImage.width > 0 && cgImage.height > 0
        }
        guard let ciImage = image.ciImage else { return false }
        let extent = ciImage.extent
        return extent.isNull == false
            && extent.isInfinite == false
            && extent.width.isFinite
            && extent.height.isFinite
            && extent.width > 0
            && extent.height > 0
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
                if Task.isCancelled { group.cancelAll(); return }
                if let image, isDisplayable(image) {
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
}
