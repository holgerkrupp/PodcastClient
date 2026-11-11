import XCTest
import SwiftUI
import UIKit
@testable import UpNext

final class TopPodcastShareCoverWallTests: XCTestCase {
    @MainActor
    func testCoverWallRendersOneAndManyCoversForPortraitSquareAndLandscape() {
        let covers = [makeCover(color: .systemBlue), makeCover(color: .systemOrange)]
        let sizes: [CGSize] = [
            CGSize(width: 96, height: 160),
            CGSize(width: 120, height: 120),
            CGSize(width: 160, height: 96)
        ]

        for size in sizes {
            for images in [[covers[0]], covers] {
                let renderer = ImageRenderer(
                    content: PodcastCoverWallBackground(images: images)
                        .frame(width: size.width, height: size.height)
                )
                renderer.scale = 1
                XCTAssertNotNil(renderer.uiImage)
            }
        }
    }

    @MainActor
    func testCoverWallRendersFallbackWhenNoCoversAreAvailable() {
        let renderer = ImageRenderer(
            content: PodcastCoverWallBackground(images: [])
                .frame(width: 120, height: 120)
        )
        renderer.scale = 1
        XCTAssertNotNil(renderer.uiImage)
    }

    @MainActor
    private func makeCover(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }
}
