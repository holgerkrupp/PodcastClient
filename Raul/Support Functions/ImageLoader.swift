import SwiftUI

actor SharedImageRepository {
    static let shared = SharedImageRepository()

    private var inFlightTasks: [URL: Task<UIImage?, Never>] = [:]
    nonisolated(unsafe) private static let memoryCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 1024 * 1024 * 150
        return cache
    }()

    nonisolated static func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    nonisolated static func store(_ image: UIImage, for url: URL, cost: Int = 0) {
        memoryCache.setObject(image, forKey: url as NSURL, cost: cost)
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
                  let image = UIImage(data: data) else {
                return nil
            }

            Self.store(image, for: url, cost: data.count)
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
        return UIImage(data: loader.imageData) ??  UIImage()
    }

    var body: some View {
        Group {
            if let image = UIImage(data: loader.imageData) {
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
    @Published var imageData = Data()

    init(imageURL: URL, saveTo: URL? = nil) {
        Task {
            self.imageData = await Self.loadImageData(from: imageURL, saveTo: saveTo) ?? Data()
        }
    }

    static func loadImageData(from url: URL, saveTo: URL?) async -> Data? {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        let cache = URLCache.shared
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
    
    static func loadUIImage(from url: URL, saveTo: URL? = nil) async -> UIImage? {
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
        return UIImage(data: data) ?? UIImage()
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
