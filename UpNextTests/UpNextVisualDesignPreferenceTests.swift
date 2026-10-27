import XCTest
import SwiftUI
import UIKit
import ESADesignKit
@testable import UpNext

final class UpNextVisualDesignPreferenceTests: XCTestCase {
    func testArtworkBlurDefaultAndInvalidPreferences() {
        XCTAssertEqual(UpNextVisualDesignPreference.artworkBlurLevel(for: 2), .standard)
        XCTAssertEqual(UpNextVisualDesignPreference.artworkBlurLevel(for: -1), .standard)
        XCTAssertEqual(UpNextVisualDesignPreference.artworkBlurLevel(for: 99), .standard)
        XCTAssertEqual(UpNextVisualDesignPreference.artworkBlurLevel(for: 0), .minimal)
        XCTAssertEqual(UpNextVisualDesignPreference.artworkBlurLevel(for: 4), .maximum)
    }

    func testWidgetAppearanceSnapshotCarriesDeviceLocalArtworkBlurLevel() throws {
        let snapshot = WidgetAppearanceSnapshot(
            schemaVersion: 1,
            visualStyle: "artwork",
            uniformColorRGB: nil,
            artworkBlurLevel: ESAArtworkBlurLevel.strong.rawValue
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetAppearanceSnapshot.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.visualStyle, "artwork")
        XCTAssertEqual(decoded.artworkBlurLevel, ESAArtworkBlurLevel.strong.rawValue)
    }

    func testLegacyWidgetAppearanceSnapshotWithoutBlurStillDecodes() throws {
        let legacy = #"{"schemaVersion":1,"visualStyle":"artwork","uniformColorRGB":null}"#
        let decoded = try JSONDecoder().decode(
            WidgetAppearanceSnapshot.self,
            from: Data(legacy.utf8)
        )
        XCTAssertNil(decoded.artworkBlurLevel)
        XCTAssertEqual(
            UpNextVisualDesignPreference.artworkBlurLevel(
                for: decoded.artworkBlurLevel ?? ESAArtworkBlurLevel.standard.rawValue
            ),
            .standard
        )
    }

    func testRGBPreferenceValidatesAndKeepsUnsetSeparateFromExplicitColor() {
        XCTAssertNil(UpNextVisualDesignPreference.validatedRGB(nil))
        XCTAssertEqual(UpNextVisualDesignPreference.validatedRGB("#abcdef"), "#ABCDEF")
        XCTAssertEqual(UpNextVisualDesignPreference.validatedRGB("123456"), "#123456")
        XCTAssertNil(UpNextVisualDesignPreference.validatedRGB("#ABC"))
        XCTAssertNil(UpNextVisualDesignPreference.validatedRGB("#GG0000"))
    }

    func testCustomBackgroundPreservesSelectedRGBAcrossColorSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let palette = UpNextVisualDesignPreference.uniformPalette(for: scheme, customRGB: "#A1B2C3")
            let rgb = try XCTUnwrap(components(palette.background))
            XCTAssertEqual(rgb.0, 161.0 / 255, accuracy: 0.005)
            XCTAssertEqual(rgb.1, 178.0 / 255, accuracy: 0.005)
            XCTAssertEqual(rgb.2, 195.0 / 255, accuracy: 0.005)
        }
    }

    func testUnsetColorRetainsTealDefaultsAndInvalidColorFallsBack() throws {
        let lightDefault = try XCTUnwrap(components(UpNextVisualDesignPreference.uniformPalette(for: .light, customRGB: nil).background))
        let invalidFallback = try XCTUnwrap(components(UpNextVisualDesignPreference.uniformPalette(for: .light, customRGB: "not-a-color").background))
        XCTAssertEqual(lightDefault.0, 212.0 / 255, accuracy: 0.005)
        XCTAssertEqual(lightDefault.1, 237.0 / 255, accuracy: 0.005)
        XCTAssertEqual(lightDefault.2, 230.0 / 255, accuracy: 0.005)
        XCTAssertEqual(lightDefault.0, invalidFallback.0, accuracy: 0.005)
        XCTAssertEqual(lightDefault.1, invalidFallback.1, accuracy: 0.005)
        XCTAssertEqual(lightDefault.2, invalidFallback.2, accuracy: 0.005)
    }

    func testPaletteTextAndSeparatorMeetContrastTargetsForExtremeColors() throws {
        for color in ["#FFFFFF", "#000000", "#E60078", "#0A5E42"] {
            let palette = UpNextVisualDesignPreference.uniformPalette(for: .dark, customRGB: color)
            let background = try XCTUnwrap(components(palette.background))
            let primary = try XCTUnwrap(components(palette.primaryForeground))
            let secondary = try XCTUnwrap(components(palette.secondaryForeground))
            let separator = try XCTUnwrap(components(palette.separator))
            XCTAssertGreaterThanOrEqual(contrast(primary, background), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(secondary, background), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(separator, background), 3.0)
        }
    }

    private func components(_ color: Color) -> (Double, Double, Double)? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return (Double(red), Double(green), Double(blue))
    }

    private func contrast(_ foreground: (Double, Double, Double), _ background: (Double, Double, Double)) -> Double {
        let first = luminance(foreground)
        let second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }
}
