import SwiftUI

struct ImageWithURL: View {
    
   @ObservedObject var imageLoader: ImageLoaderAndCache
    
    init(_ url: URL) {
        imageLoader = ImageLoaderAndCache(imageURL: url)
    }
    
    
    
    var body: some View {
        Image(uiImage: (UIImage(data: self.imageLoader.imageData) ?? UIImage()))
            .resizable()
            .clipped()
    }
}


@MainActor
class ImageLoaderAndCache: ObservableObject {
    
    @Published var imageData = Data()
    
    init(imageURL: URL) {
        
        let cache = URLCache()
        cache.diskCapacity = 100 * 1024 * 1024 // 100MB
        
        // let cache = URLCache.shared
        let request = URLRequest(url: imageURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 60.0)
        
        if let data = cache.cachedResponse(for: request)?.data {
            self.imageData = data
        } else {
            // Weakly capture self to avoid a strong reference cycle
            URLSession.shared.dataTask(with: request) { [weak self] (data, response, error) in
                // Ensure self is still available
                guard let self = self else { return }
                
                if let data = data, let response = response {
                    let cachedData = CachedURLResponse(response: response, data: data)
                    cache.storeCachedResponse(cachedData, for: request)
                    
                    // Ensure updates to @Published properties are done on the main thread
                    DispatchQueue.main.async {
                        self.imageData = data
                    }
                }
            }.resume()
        }
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
