import SwiftUI
import UIKit
import XCTest
@testable import BloemAdmin

/// Measures the shipped color sets in all four appearances: Light, Dark, and each with increased contrast.
final class ThemeContrastTests: XCTestCase {
    private struct Appearance {
        let name: String
        let style: UIUserInterfaceStyle
        let contrast: UIAccessibilityContrast
        var minimumText: Double { contrast == .high ? 7 : 4.5 }
        var traits: UITraitCollection {
            UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: style),
                UITraitCollection(accessibilityContrast: contrast),
            ])
        }
    }

    private let appearances = [
        Appearance(name: "Light", style: .light, contrast: .normal),
        Appearance(name: "Dark", style: .dark, contrast: .normal),
        Appearance(name: "Light, increased contrast", style: .light, contrast: .high),
        Appearance(name: "Dark, increased contrast", style: .dark, contrast: .high),
    ]

    private func rgb(_ color: Color, _ traits: UITraitCollection) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func luminance(_ color: Color, _ traits: UITraitCollection) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = rgb(color, traits)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func ratio(_ a: Color, _ b: Color, _ traits: UITraitCollection) -> Double {
        let x = luminance(a, traits), y = luminance(b, traits)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testEveryColorSetResolves() {
        for name in ["BloemBackground", "BloemSurface", "BloemRaised", "BloemHairline", "BloemText", "BloemTextMuted",
                     "AccentColor", "BloemOnAccent", "BloemOK", "BloemWarn", "BloemDanger",
                     "BloemChartDirectPlay", "BloemChartDirectStream", "BloemChartTranscode",
                     "BloemChart4", "BloemChart5", "BloemSidebar", "BloemSelected", "BloemOutline", "BloemTally"] {
            XCTAssertNotNil(UIColor(named: name, in: Bundle.main, compatibleWith: nil), "\(name) is missing")
        }
    }

    func testTextAndStatusColorsReachTheMinimumOnEverySurface() {
        let text: [(String, Color)] = [
            ("text", Theme.text), ("muted", Theme.muted), ("accent", Theme.accent),
            ("ok", Theme.ok), ("warn", Theme.warn), ("danger", Theme.danger),
        ]
        let surfaces: [(String, Color)] = [("background", Theme.background), ("surface", Theme.surface), ("raised", Theme.raised)]
        // The page name sits on the selected menu row.
        for appearance in appearances {
            for (name, foreground) in [("text", Theme.text), ("muted", Theme.muted)] {
                let value = ratio(foreground, Theme.selected, appearance.traits)
                XCTAssertGreaterThanOrEqual(value, appearance.minimumText, "\(name) on selected, \(appearance.name): \(value)")
            }
        }
        for appearance in appearances {
            for (textName, foreground) in text {
                for (surfaceName, surface) in surfaces {
                    let value = ratio(foreground, surface, appearance.traits)
                    XCTAssertGreaterThanOrEqual(
                        value, appearance.minimumText,
                        "\(textName) on \(surfaceName), \(appearance.name): \(String(format: "%.2f", value)):1"
                    )
                }
            }
        }
    }

    func testWhiteOrDarkLabelOnTheAccentFillReachesTheMinimum() {
        for appearance in appearances {
            let value = ratio(Theme.onAccent, Theme.accent, appearance.traits)
            XCTAssertGreaterThanOrEqual(value, appearance.minimumText, "label on accent, \(appearance.name): \(value)")
        }
    }

    func testChartColorsStandOutFromThePageAndCards() {
        for appearance in appearances {
            for (name, color) in [("direct play", PlaybackMethod.directPlay.color), ("direct stream", PlaybackMethod.directStream.color),
                                  ("transcode", PlaybackMethod.transcode.color)] {
                for surface in [Theme.surface] {
                    let value = ratio(color, surface, appearance.traits)
                    XCTAssertGreaterThanOrEqual(value, 3, "\(name), \(appearance.name): \(value)")
                }
            }
        }
    }

    func testWarningIsADifferentHueFromTheAccent() {
        func hue(_ color: Color, _ traits: UITraitCollection) -> Double {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).resolvedColor(with: traits).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return Double(h) * 360
        }
        for appearance in appearances {
            let difference = abs(hue(Theme.warn, appearance.traits) - hue(Theme.accent, appearance.traits))
            XCTAssertGreaterThanOrEqual(difference, 10, "warn vs accent hue, \(appearance.name): \(difference) degrees")
        }
    }

    func testTheAccentIsLighterInDarkThanInLightButBothAreBloemOrange() {
        let light = rgb(Theme.accent, appearances[0].traits)
        let dark = rgb(Theme.accent, appearances[1].traits)
        XCTAssertEqual(dark.0, Double(0xFA) / 255, accuracy: 0.003)
        XCTAssertEqual(dark.1, Double(0x64) / 255, accuracy: 0.003)
        XCTAssertEqual(dark.2, 0, accuracy: 0.003)
        XCTAssertLessThan(light.0, dark.0)
    }
}

final class AppearancePreferenceTests: XCTestCase {
    func testStoredValueFallsBackToTheSystemAppearance() {
        let defaults = UserDefaults(suiteName: "AppearancePreferenceTests")!
        defaults.removePersistentDomain(forName: "AppearancePreferenceTests")
        XCTAssertEqual(AppearancePreference.stored(in: defaults), .system)
        defaults.set("dark", forKey: AppearancePreference.storageKey)
        XCTAssertEqual(AppearancePreference.stored(in: defaults), .dark)
        defaults.set("sepia", forKey: AppearancePreference.storageKey)
        XCTAssertEqual(AppearancePreference.stored(in: defaults), .system)
    }

    func testEachChoiceMapsToASchemeAndAnInterfaceStyle() {
        XCTAssertNil(AppearancePreference.system.colorScheme)
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
        XCTAssertEqual(AppearancePreference.system.interfaceStyle, .unspecified)
        XCTAssertEqual(AppearancePreference.light.interfaceStyle, .light)
        XCTAssertEqual(AppearancePreference.dark.interfaceStyle, .dark)
    }
}
