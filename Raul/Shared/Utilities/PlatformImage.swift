#if !canImport(UIKit)
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

final class UIImage: NSObject, @unchecked Sendable {
    enum Orientation {
        case up
    }

    let cgImage: CGImage?
    let scale: CGFloat
    let imageOrientation: Orientation

    var size: CGSize {
        guard let cgImage else { return .zero }
        return CGSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        )
    }

    override init() {
        cgImage = nil
        scale = 1
        imageOrientation = .up
        super.init()
    }

    init(cgImage: CGImage, scale: CGFloat = 1, orientation: Orientation = .up) {
        self.cgImage = cgImage
        self.scale = max(scale, 1)
        imageOrientation = orientation
        super.init()
    }

    convenience init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        self.init(cgImage: image)
    }

    convenience init?(named: String) {
        return nil
    }

    convenience init?(systemName: String) {
        return nil
    }

    func pngData() -> Data? {
        encodedData(type: UTType.png.identifier as CFString)
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        encodedData(
            type: UTType.jpeg.identifier as CFString,
            properties: [kCGImageDestinationLossyCompressionQuality: compressionQuality]
        )
    }

    private func encodedData(
        type: CFString,
        properties: [CFString: Any] = [:]
    ) -> Data? {
        guard let cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension Image {
    init(uiImage: UIImage) {
        if let cgImage = uiImage.cgImage {
            self.init(
                decorative: cgImage,
                scale: uiImage.scale,
                orientation: .up
            )
        } else {
            self.init(systemName: "photo")
        }
    }
}
#endif
