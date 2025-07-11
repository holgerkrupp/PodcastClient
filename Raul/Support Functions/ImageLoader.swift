import SwiftUI



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
            print("Image loading failed: \(error)")
            return nil
        }
    }
    
    static func loadUIImage(from url: URL, saveTo: URL? = nil) async -> UIImage? {
        if let data = await loadImageData(from: url, saveTo: saveTo) {
            return UIImage(data: data)
        }
        return nil
    }
}


struct ImageWithData: View {
    
     var image:Image?
    var data : Data
    
    
    init(_ data: Data) {
        
        self.data = data
        self.image = createImage()
      //  print("load image from data")
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
