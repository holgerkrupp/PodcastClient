import Foundation
import CoreImage
import ImageIO
import SwiftUI

actor SharedImageRepository {
    static let shared = SharedImageRepository()

    private var inFlightDataTasks: [URL: Task<Data?, Never>] = [:]
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]
    private var inFlightBlurredTasks: [String: Task<UIImage?, Never>] = [:]
    private static let ciContext = CIContext(options: [.cacheIntermediates: true])

    nonisolated(unsafe) private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 1024 * 1024 * 96
        return cache
    }()

    nonisolated(unsafe) private static let blurredMemoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 1024 * 1024 * 96
        return cache
    }()

    nonisolated static func cachedImage(
        for url: URL,
        maxPixelSize: CGFloat = ImageLoaderAndCache.defaultMaxPixelSize
    ) -> UIImage? {
        memoryCache.object(forKey: imageCacheKey(for: url, maxPixelSize: maxPixelSize) as NSString)
    }

    nonisolated static func store(
        _ image: UIImage,
        for url: URL,
        maxPixelSize: CGFloat,
        cost: Int = 0
    ) {
        memoryCache.setObject(
            image,
            forKey: imageCacheKey(for: url, maxPixelSize: maxPixelSize) as NSString,
            cost: cost
        )
    }

    nonisolated static func cachedBlurredImage(for key: String) -> UIImage? {
        blurredMemoryCache.object(forKey: key as NSString)
    }

    nonisolated static func storeBlurredImage(_ image: UIImage, for key: String, cost: Int = 0) {
        blurredMemoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    nonisolated static func memoryCost(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return max(cgImage.bytesPerRow * cgImage.height, 1)
        }

        let width = max(Int(image.size.width * image.scale), 1)
        let height = max(Int(image.size.height * image.scale), 1)
        return width * height * 4
    }

    func image(
        for url: URL,
        maxPixelSize: CGFloat = ImageLoaderAndCache.defaultMaxPixelSize,
        saveTo: URL? = nil
    ) async -> UIImage? {
        if let cached = Self.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            return cached
        }

        let cacheKey = Self.imageCacheKey(for: url, maxPixelSize: maxPixelSize)
        if let task = inFlightTasks[cacheKey] {
            return await task.value
        }

        // A visible cover should not inherit the lower priority of a decorative
        // blurred-image request that happened to reach the repository first.
        let task = Task<UIImage?, Never>(priority: .userInitiated) {
            if let image = await Self.loadPersistedImage(
                for: url,
                maxPixelSize: maxPixelSize
            ) {
                Self.store(
                    image,
                    for: url,
                    maxPixelSize: maxPixelSize,
                    cost: Self.memoryCost(for: image)
                )
                return image
            }

            guard let data = await self.imageData(for: url),
                  let image = ImageLoaderAndCache.makeUIImage(
                    from: data,
                    maxPixelSize: maxPixelSize
                  ) else {
                return nil
            }

            if let saveTo {
                try? data.write(to: saveTo)
            }

            Self.store(
                image,
                for: url,
                maxPixelSize: maxPixelSize,
                cost: Self.memoryCost(for: image)
            )
            await Self.persist(
                image,
                sourceURL: url,
                variant: .image(maxPixelSize: maxPixelSize)
            )
            return image
        }

        inFlightTasks[cacheKey] = task
        let image = await task.value
        inFlightTasks[cacheKey] = nil
        return image
    }

    func persistedImage(
        for url: URL,
        maxPixelSize: CGFloat = ImageLoaderAndCache.defaultMaxPixelSize
    ) async -> UIImage? {
        if let cached = Self.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            return cached
        }
        guard let image = await Self.loadPersistedImage(
            for: url,
            maxPixelSize: maxPixelSize
        ) else {
            return nil
        }
        Self.store(
            image,
            for: url,
            maxPixelSize: maxPixelSize,
            cost: Self.memoryCost(for: image)
        )
        return image
    }

    func blurredImage(
        for url: URL,
        radius: CGFloat,
        maxPixelSize: CGFloat = ImageLoaderAndCache.defaultMaxPixelSize,
        saveTo: URL? = nil
    ) async -> UIImage? {
        let key = Self.blurredCacheKey(for: url, radius: radius, maxPixelSize: maxPixelSize)
        if let cached = Self.cachedBlurredImage(for: key) {
            return cached
        }

        if let task = inFlightBlurredTasks[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never>(priority: .utility) {
            if let image = await Self.loadPersistedBlurredImage(
                for: url,
                radius: radius,
                maxPixelSize: maxPixelSize
            ) {
                Self.storeBlurredImage(image, for: key, cost: Self.memoryCost(for: image))
                return image
            }

            guard let sourceImage = await self.image(
                    for: url,
                    maxPixelSize: maxPixelSize,
                    saveTo: saveTo
                  ),
                  let blurredImage = Self.makeBlurredImage(
                    from: sourceImage,
                    radius: radius,
                    maxPixelSize: maxPixelSize
                  ) else {
                return nil
            }

            Self.storeBlurredImage(blurredImage, for: key, cost: Self.memoryCost(for: blurredImage))
            await Self.persist(
                blurredImage,
                sourceURL: url,
                variant: .blurred(radius: radius, maxPixelSize: maxPixelSize)
            )
            return blurredImage
        }

        inFlightBlurredTasks[key] = task
        let image = await task.value
        inFlightBlurredTasks[key] = nil
        return image
    }

    /// Coalesces the original byte download independently of decoded size.
    /// Inbox rows, blurred backgrounds, and larger destinations can therefore
    /// request the same artwork concurrently without starting multiple HTTP
    /// transfers for that URL.
    private func imageData(for url: URL) async -> Data? {
        if let task = inFlightDataTasks[url] {
            return await task.value
        }

        let task = Task<Data?, Never>(priority: .userInitiated) {
            await ImageLoaderAndCache.loadImageData(from: url, saveTo: nil)
        }
        inFlightDataTasks[url] = task
        let data = await task.value
        inFlightDataTasks[url] = nil
        return data
    }

    func persistedBlurredImage(
        for url: URL,
        radius: CGFloat,
        maxPixelSize: CGFloat = ImageLoaderAndCache.defaultMaxPixelSize
    ) async -> UIImage? {
        let key = Self.blurredCacheKey(for: url, radius: radius, maxPixelSize: maxPixelSize)
        if let cached = Self.cachedBlurredImage(for: key) {
            return cached
        }
        guard let image = await Self.loadPersistedBlurredImage(
            for: url,
            radius: radius,
            maxPixelSize: maxPixelSize
        ) else {
            return nil
        }
        Self.storeBlurredImage(image, for: key, cost: Self.memoryCost(for: image))
        return image
    }

    nonisolated static func imageCacheKey(for url: URL, maxPixelSize: CGFloat) -> String {
        "\(url.absoluteString)|max:\(Int(maxPixelSize.rounded(.up)))"
    }

    nonisolated static func blurredCacheKey(
        for url: URL,
        radius: CGFloat,
        maxPixelSize: CGFloat = ImageLoaderAndCache.defaultMaxPixelSize
    ) -> String {
        "\(url.absoluteString)|blur:\(Int(radius.rounded()))|max:\(Int(maxPixelSize.rounded()))"
    }

    nonisolated private static func makeBlurredImage(
        from image: UIImage,
        radius: CGFloat,
        maxPixelSize: CGFloat
    ) -> UIImage? {
#if canImport(UIKit)
        guard let inputImage = CIImage(image: image) else { return nil }
#else
        guard let sourceImage = image.cgImage else { return nil }
        let inputImage = CIImage(cgImage: sourceImage)
#endif

        let longestEdge = max(inputImage.extent.width, inputImage.extent.height)
        let scale = longestEdge > 0 ? min(1, max(maxPixelSize, 1) / longestEdge) : 1
        let scaledImage = scale < 1
            ? inputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : inputImage
        let clampedImage = scaledImage.clampedToExtent()
        let blurredImage = clampedImage
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: scaledImage.extent)

        guard let cgImage = ciContext.createCGImage(blurredImage, from: scaledImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func loadPersistedImage(
        for url: URL,
        maxPixelSize: CGFloat
    ) async -> UIImage? {
        guard url.isFileURL == false else { return nil }

        if let data = await ArtworkDiskCache.shared.cachedData(
                for: url,
                variant: .image(maxPixelSize: maxPixelSize)
              ) {
            return ImageLoaderAndCache.makeUIImage(from: data, maxPixelSize: maxPixelSize)
        }

        // Downloaded episodes retain a full-size display variant. Smaller row
        // requests can reuse it while offline instead of requiring a duplicate.
        guard maxPixelSize < ImageLoaderAndCache.defaultMaxPixelSize,
              let fallbackData = await ArtworkDiskCache.shared.cachedData(
                for: url,
                variant: .image(maxPixelSize: ImageLoaderAndCache.defaultMaxPixelSize)
              ) else {
            return nil
        }
        return ImageLoaderAndCache.makeUIImage(from: fallbackData, maxPixelSize: maxPixelSize)
    }

    private static func loadPersistedBlurredImage(
        for url: URL,
        radius: CGFloat,
        maxPixelSize: CGFloat
    ) async -> UIImage? {
        guard url.isFileURL == false,
              let data = await ArtworkDiskCache.shared.cachedData(
                for: url,
                variant: .blurred(radius: radius, maxPixelSize: maxPixelSize)
              ) else {
            return nil
        }
        return ImageLoaderAndCache.makeUIImage(from: data, maxPixelSize: maxPixelSize)
    }

    private static func persist(
        _ image: UIImage,
        sourceURL: URL,
        variant: ArtworkDiskCache.Variant
    ) async {
        guard sourceURL.isFileURL == false,
              let data = encodedCacheData(for: image) else {
            return
        }
        await ArtworkDiskCache.shared.store(data, for: sourceURL, variant: variant)
    }

    nonisolated private static func encodedCacheData(for image: UIImage) -> Data? {
        guard let alphaInfo = image.cgImage?.alphaInfo else {
            return image.jpegData(compressionQuality: 0.82)
        }
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return image.pngData()
        case .none, .noneSkipFirst, .noneSkipLast, .alphaOnly:
            return image.jpegData(compressionQuality: 0.82)
        @unknown default:
            return image.jpegData(compressionQuality: 0.82)
        }
    }
}

struct ImageWithURL: View {
    @StateObject private var loader: ImageLoaderAndCache

    init(_ url: URL, saveTo: URL? = nil) {
        _loader = StateObject(wrappedValue: ImageLoaderAndCache(imageURL: url, saveTo: saveTo))
    }
    
    func uiImage() -> UIImage{
        loader.image ?? UIImage()
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .clipped()
            } else {
                ProgressView()
            }
        }
    }
}

@MainActor
class ImageLoaderAndCache: ObservableObject {
    nonisolated static let defaultMaxPixelSize: CGFloat = 1400

    @Published var image: UIImage?

    init(imageURL: URL, saveTo: URL? = nil) {
        Task {
            self.image = await Self.loadUIImage(from: imageURL, saveTo: saveTo)
        }
    }

    nonisolated static func loadImageData(from url: URL, saveTo: URL?) async -> Data? {
        guard url.isFileURL || url.scheme?.lowercased() != "about" else {
            return nil
        }

        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        let cache = URLCache.shared
        cache.memoryCapacity = 1024 * 1024 * 16
        cache.diskCapacity = 1024 * 1024 * 200
        
        if let cached = cache.cachedResponse(for: request)?.data {
          
            return cached
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let cachedResponse = CachedURLResponse(response: response, data: data)
            cache.storeCachedResponse(cachedResponse, for: request)

            if let saveTo {
                try? data.write(to: saveTo)
            }
           
            return data
        } catch {
            // print("Image loading failed: \(error)")
            return nil
        }
    }

    nonisolated static func makeUIImage(from data: Data, maxPixelSize: CGFloat = defaultMaxPixelSize) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maxPixelSize.rounded(.up)), 1),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return UIImage(data: data)
        }

        return UIImage(cgImage: cgImage)
    }
    
    nonisolated static func loadUIImage(
        from url: URL,
        maxPixelSize: CGFloat = defaultMaxPixelSize,
        saveTo: URL? = nil
    ) async -> UIImage? {
        await SharedImageRepository.shared.image(
            for: url,
            maxPixelSize: maxPixelSize,
            saveTo: saveTo
        )
    }

    nonisolated static func loadPersistedUIImage(
        from url: URL,
        maxPixelSize: CGFloat = defaultMaxPixelSize
    ) async -> UIImage? {
        await SharedImageRepository.shared.persistedImage(
            for: url,
            maxPixelSize: maxPixelSize
        )
    }

    nonisolated static func loadBlurredUIImage(
        from url: URL,
        radius: CGFloat,
        maxPixelSize: CGFloat = defaultMaxPixelSize,
        saveTo: URL? = nil
    ) async -> UIImage? {
        await SharedImageRepository.shared.blurredImage(
            for: url,
            radius: radius,
            maxPixelSize: maxPixelSize,
            saveTo: saveTo
        )
    }

    nonisolated static func loadPersistedBlurredUIImage(
        from url: URL,
        radius: CGFloat,
        maxPixelSize: CGFloat = defaultMaxPixelSize
    ) async -> UIImage? {
        await SharedImageRepository.shared.persistedBlurredImage(
            for: url,
            radius: radius,
            maxPixelSize: maxPixelSize
        )
    }
}


struct ImageWithData: View {
    
     var image:Image?
    var data : Data
    
    
    init(_ data: Data) {
        
        self.data = data
        self.image = createImage()
      //  // print("load image from data")
    }
    
    var body: some View {
        image?
            .resizable()
            
    }
    
    func uiImage() -> UIImage{
        ImageLoaderAndCache.makeUIImage(from: data) ?? UIImage()
    }
    
    func createImage() -> Image {
        let cover: UIImage = uiImage()
        return Image(uiImage: cover)
    }
}
