import Foundation
import ImageIO
import SwiftUI

actor SharedImageRepository {
    static let shared = SharedImageRepository()

    private var inFlightTasks: [URL: Task<UIImage?, Never>] = [:]
    nonisolated(unsafe) private static let memoryCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 1024 * 1024 * 96
        return cache
    }()

    nonisolated static func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    nonisolated static func store(_ image: UIImage, for url: URL, cost: Int = 0) {
        memoryCache.setObject(image, forKey: url as NSURL, cost: cost)
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
#if canImport(UIKit)
        let cover: UIImage = uiImage()
        return Image(uiImage: cover)
#elseif canImport(AppKit)
        let cover: NSImage = NSImage(data: data) ?? NSImage()
        return Image(nsImage: cover)
#else
        return Image(systemImage: "some_default")
#endif
    }
}
