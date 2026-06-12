import Foundation
import CoreImage
import ImageIO
import SwiftUI

actor SharedImageRepository {
    static let shared = SharedImageRepository()

    private var inFlightTasks: [URL: Task<UIImage?, Never>] = [:]
    private var inFlightBlurredTasks: [String: Task<UIImage?, Never>] = [:]
    private static let ciContext = CIContext(options: [.cacheIntermediates: true])

    nonisolated(unsafe) private static let memoryCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
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

    nonisolated static func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    nonisolated static func store(_ image: UIImage, for url: URL, cost: Int = 0) {
        memoryCache.setObject(image, forKey: url as NSURL, cost: cost)
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

    func image(for url: URL, saveTo: URL? = nil) async -> UIImage? {
        if let cached = Self.cachedImage(for: url) {
            return cached
        }

        if let task = inFlightTasks[url] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
            guard let data = await ImageLoaderAndCache.loadImageData(from: url, saveTo: saveTo),
                  let image = ImageLoaderAndCache.makeUIImage(from: data) else {
                return nil
            }

            Self.store(image, for: url, cost: Self.memoryCost(for: image))
            return image
        }

        inFlightTasks[url] = task
        let image = await task.value
        inFlightTasks[url] = nil
        return image
    }

    func blurredImage(for url: URL, radius: CGFloat, saveTo: URL? = nil) async -> UIImage? {
        let key = Self.blurredCacheKey(for: url, radius: radius)
        if let cached = Self.cachedBlurredImage(for: key) {
            return cached
        }

        if let task = inFlightBlurredTasks[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
            guard let sourceImage = await self.image(for: url, saveTo: saveTo),
                  let blurredImage = Self.makeBlurredImage(from: sourceImage, radius: radius) else {
                return nil
            }

            Self.storeBlurredImage(blurredImage, for: key, cost: Self.memoryCost(for: blurredImage))
            return blurredImage
        }

        inFlightBlurredTasks[key] = task
        let image = await task.value
        inFlightBlurredTasks[key] = nil
        return image
    }

    nonisolated static func blurredCacheKey(for url: URL, radius: CGFloat) -> String {
        "\(url.absoluteString)|blur:\(Int(radius.rounded()))"
    }

    nonisolated private static func makeBlurredImage(from image: UIImage, radius: CGFloat) -> UIImage? {
#if canImport(UIKit)
        guard let inputImage = CIImage(image: image) else { return nil }
#else
        guard let sourceImage = image.cgImage else { return nil }
        let inputImage = CIImage(cgImage: sourceImage)
#endif

        let clampedImage = inputImage.clampedToExtent()
        let blurredImage = clampedImage
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: inputImage.extent)

        guard let cgImage = ciContext.createCGImage(blurredImage, from: inputImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
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
    
    nonisolated static func loadUIImage(from url: URL, saveTo: URL? = nil) async -> UIImage? {
        await SharedImageRepository.shared.image(for: url, saveTo: saveTo)
    }

    nonisolated static func loadBlurredUIImage(from url: URL, radius: CGFloat, saveTo: URL? = nil) async -> UIImage? {
        await SharedImageRepository.shared.blurredImage(for: url, radius: radius, saveTo: saveTo)
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
