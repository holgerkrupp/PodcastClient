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

class ImageLoaderAndCache: ObservableObject {
    
    @Published var imageData = Data()
    
    init(imageURL: URL) {
        
        let cache = URLCache()
        cache.diskCapacity = 100*1024*1024 // 100MB
        
       // let cache = URLCache.shared
        let request = URLRequest(url: imageURL, cachePolicy: URLRequest.CachePolicy.returnCacheDataElseLoad, timeoutInterval: 60.0)
        if let data = cache.cachedResponse(for: request)?.data {
            print("got image from cache")
            self.imageData = data
        } else {
            URLSession.shared.dataTask(with: request, completionHandler: { (data, response, error) in
                if let data = data, let response = response {
                    let cachedData = CachedURLResponse(response: response, data: data)
                    cache.storeCachedResponse(cachedData, for: request)
                    DispatchQueue.main.async {
                        print("downloaded from internet")
                        self.imageData = data
                    }
                }
            }).resume()
        }
    }
}
