import CarPlay
import UIKit
import XCTest
@testable import UpNext

final class CarPlayArtworkProviderTests: XCTestCase {
    func testMissingAndMalformedArtworkDoNotProduceAnImage() {
        XCTAssertFalse(CarPlayArtworkProvider.isDisplayable(UIImage()))
        XCTAssertNil(CarPlayArtworkProvider.loadImage(from: Data([0, 1, 2, 3]), maxPixelSize: 180))
    }

    func testPixelBudgetUsesDisplayScaleAndStaysBoundedByCarPlaySize() async {
        let oneX = await CarPlayArtworkProvider.pixelBudget(displayScale: 1)
        let threeX = await CarPlayArtworkProvider.pixelBudget(displayScale: 3)
        XCTAssertGreaterThan(threeX, oneX)
        XCTAssertLessThanOrEqual(threeX, 512)
        XCTAssertGreaterThanOrEqual(oneX, 32)
    }

    func testValidImageIsAccepted() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        XCTAssertTrue(CarPlayArtworkProvider.isDisplayable(image))
    }

    func testArtworkLoadsRemainBoundedForLargeLists() async {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
        }
        let counter = ConcurrentArtworkLoadCounter()
        let requests = (0..<500).map {
            (index: $0, url: URL(string: "https://example.invalid/\($0).png")!)
        }

        await CarPlayArtworkProvider.loadBounded(
            requests: requests,
            maxPixelSize: 180,
            loader: { _, _ in
                await counter.begin()
                try? await Task.sleep(for: .milliseconds(1))
                await counter.end()
                return image
            },
            didLoad: { _, _ in }
        )

        let maximum = await counter.maximum
        let completed = await counter.completed
        XCTAssertLessThanOrEqual(maximum, CarPlayArtworkProvider.maximumConcurrentLoads)
        XCTAssertEqual(completed, 500)
    }
}

private actor ConcurrentArtworkLoadCounter {
    private(set) var active = 0
    private(set) var maximum = 0
    private(set) var completed = 0

    func begin() {
        active += 1
        maximum = max(maximum, active)
    }

    func end() {
        active -= 1
        completed += 1
    }
}
