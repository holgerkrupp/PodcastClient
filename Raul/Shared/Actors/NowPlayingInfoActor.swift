//
//  NowPlayingUpdater.swift
//  Raul
//
//  Created by Holger Krupp on 12.07.25.
//

import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif


class NowPlayingInfoActor {
    private var info: [String: Any] = [:]
    private var artwork: MPMediaItemArtwork?
    
 //   static let shared = NowPlayingInfoActor()
    
    
    
    func updateInfo(_ info: [String: Any]) {
        var info = info
        
        if let artwork = artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        self.info = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    func setArtwork(_ image: UIImage) {
#if canImport(UIKit)
        // The same image arrives again after unrelated player updates.
        guard image !== artworkSource else { return }
        artworkSource = image
        // Whatever decoded the image, the system only gets a small, finite bitmap.
        guard let bounded = Self.boundedArtworkImage(image) else {
            setArtwork(nil as MPMediaItemArtwork?)
            return
        }
        let artwork = MPMediaItemArtwork(boundsSize: bounded.size) { _ in
            return bounded
        }
        setArtwork(artwork)
#endif
    }

#if canImport(UIKit)
    private var artworkSource: UIImage?
    static let maximumArtworkPixelSize: CGFloat = 1024

    /// Returns a scale-1 bitmap no larger than `maxPixelSize` on its longest
    /// edge, or nil for an image without usable dimensions.
    static func boundedArtworkImage(_ image: UIImage, maxPixelSize: CGFloat = maximumArtworkPixelSize) -> UIImage? {
        let pixelSize: CGSize
        if let cgImage = image.cgImage {
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        }
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        let longestEdge = max(pixelSize.width, pixelSize.height)
        if longestEdge <= maxPixelSize, image.cgImage != nil, image.scale == 1 {
            return image
        }
        let ratio = min(1, maxPixelSize / longestEdge)
        let targetSize = CGSize(
            width: max(1, (pixelSize.width * ratio).rounded()),
            height: max(1, (pixelSize.height * ratio).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
#endif

    func setArtwork(_ artwork: MPMediaItemArtwork?) {
        self.artwork = artwork
#if canImport(UIKit)
        if artwork == nil { artworkSource = nil }
#endif
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            if let artwork = artwork {
                // print("chanening artwork")
                info[MPMediaItemPropertyArtwork] = artwork
                self.info = info
            } else {
                // print("removing artwork")
                info.removeValue(forKey: MPMediaItemPropertyArtwork)
                self.info = info
            }
            
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    func updateField(key: String, value: Any) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[key] = value
        if let artwork = artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        self.info = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        self.info = [:]
        self.artwork = nil
#if canImport(UIKit)
        artworkSource = nil
#endif
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
