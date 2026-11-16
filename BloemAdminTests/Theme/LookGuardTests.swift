import SwiftUI
import UIKit
import XCTest
@testable import BloemAdmin

/// The shared Bloem look (docs/design.md) as checks: one typeface, one icon set, the type scale.
/// The first two scan the sources, so a system font or an SF Symbol cannot come back unnoticed.
final class LookGuardTests: XCTestCase {
    /// App and widget sources, without comment lines. BloemFont.swift is the one file that may touch `.font(`.
    private func sources() throws -> [SourceTree.File] {
        try (SourceTree.appSources().map { $0 } + SourceTree.sources(in: "BloemAdminWidgets")).map { file in
            SourceTree.File(path: file.path, lines: file.lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
        }
    }

    private func hits(_ patterns: [String], excluding: Set<String> = []) throws -> [String] {
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        var found: [String] = []
        for file in try sources() where !excluding.contains((file.path as NSString).lastPathComponent) {
            for (index, line) in file.lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regexes.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                    found.append("\(file.path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return found
    }

    func testNoSFSymbolIsUsedAnywhere() throws {
        let found = try hits([
            #"systemImage"#, #"systemName"#, #"SymbolName"#, #"SymbolEffect"#, #"symbolRenderingMode"#,
            #"symbolVariant"#, #"\bContentUnavailableView\b"#, #"\bSF Symbol"#,
        ])
        XCTAssertEqual(found, [], "Icons are Lucide (BloemIcon); an empty page is a BloemEmptyState")
        // The Info.plist files name the Home Screen quick actions' icons; none may be a symbol.
        for plist in ["BloemAdmin/Info.plist", "BloemAdminWidgets/Info.plist"] {
            let text = try String(contentsOf: SourceTree.root.appendingPathComponent(plist), encoding: .utf8)
            XCTAssertFalse(text.contains("IconSymbolName"), "\(plist) names an SF Symbol")
        }
    }

    func testNoSystemFontIsUsedAnywhere() throws {
        let found = try hits([
            #"\.font\("#, #"\.system\("#, #"design: \."#, #"\.monospaced\(\)"#, #"\.monospacedDigit\(\)"#,
            #"\.fontWeight\("#, #"\.bold\(\)"#, #"\.fontDesign"#, #"systemFont"#, #"preferredFont"#, #"Font\.TextStyle"#,
            #"\.fontWidth"#, #"\.italic\(\)"#, #"\.textCase\(\.(uppercase|lowercase)"#,
        ], excluding: ["BloemFont.swift"])
        XCTAssertEqual(found, [], "Text is set with .bloemText(<named style>), which is always Plus Jakarta Sans")
    }

    func testEveryIconIsInTheCatalogAsATemplateAndNoImageIsOrphaned() throws {
        for icon in BloemIcon.allCases {
            let image = UIImage(named: icon.assetName, in: Bundle(for: LookGuardTests.self), with: nil)
                ?? UIImage(named: icon.assetName)
            XCTAssertNotNil(image, "\(icon.assetName) is in Icons.xcassets")
            XCTAssertEqual(image?.renderingMode, .alwaysTemplate, "\(icon.assetName) takes the colour of its text")
        }
        let catalog = SourceTree.root.appendingPathComponent("BloemAdmin/Resources/Icons.xcassets")
        let folders = try FileManager.default.contentsOfDirectory(atPath: catalog.path)
            .filter { $0.hasSuffix(".imageset") }
            .map { String($0.dropLast(".imageset".count)) }
        XCTAssertEqual(Set(folders), Set(BloemIcon.allCases.map(\.assetName)), "the catalog and BloemIcon list the same icons")
        XCTAssertEqual(Set(BloemIcon.allCases.map(\.rawValue)).count, BloemIcon.allCases.count)
    }

    func testTheWidgetsLucideNamesAreInTheirOwnCatalog() throws {
        let catalog = SourceTree.root.appendingPathComponent("BloemAdminWidgets/Icons.xcassets")
        let shipped = Set(try FileManager.default.contentsOfDirectory(atPath: catalog.path)
            .filter { $0.hasSuffix(".imageset") }.map { String($0.dropLast(".imageset".count)) })
        let named = Set(try SourceTree.sources(in: "BloemAdminWidgets").flatMap { file in
            file.lines.flatMap { line -> [String] in
                line.components(separatedBy: "\"").filter { $0.hasPrefix(BloemIcon.assetPrefix) }
            }
        })
        XCTAssertFalse(named.isEmpty)
        XCTAssertTrue(named.isSubset(of: shipped), "missing from BloemAdminWidgets/Icons.xcassets: \(named.subtracting(shipped))")
    }

    // MARK: The type scale

    func testTheScaleIsTheSharedOne() {
        // size / line height / weight, from docs/design.md.
        let spec: [(BloemTextStyle, CGFloat, CGFloat, BloemWeight)] = [
            (.displayLarge, 45, 52, .semibold), (.displayMedium, 36, 44, .semibold), (.displaySmall, 32, 40, .semibold),
            (.headlineLarge, 28, 36, .semibold), (.headlineMedium, 24, 32, .semibold), (.headlineSmall, 22, 28, .semibold),
            (.titleLarge, 20, 28, .semibold), (.titleMedium, 16, 24, .medium), (.titleSmall, 14, 20, .medium),
            (.bodyLarge, 16, 24, .regular), (.bodyMedium, 14, 20, .regular), (.bodySmall, 12, 16, .regular),
            (.labelLarge, 14, 20, .medium), (.labelMedium, 12, 16, .medium), (.labelSmall, 11, 16, .medium),
        ]
        XCTAssertEqual(spec.count, BloemTextStyle.allCases.count)
        for (style, size, line, weight) in spec {
            XCTAssertEqual(style.size, size, "\(style) size")
            XCTAssertEqual(style.lineHeight, line, "\(style) line height")
            XCTAssertEqual(style.weight, weight, "\(style) weight")
        }
        XCTAssertEqual(Set(BloemTextStyle.allCases.map(\.weight.rawValue)), [400, 500, 600], "three weights only")
    }

    func testEveryStyleIsSetInPlusJakartaSans() {
        for style in BloemTextStyle.allCases {
            let font = BloemFont.uiFont(style)
            XCTAssertEqual(font.familyName, "Plus Jakarta Sans", "\(style)")
            XCTAssertEqual(font.pointSize, style.size, accuracy: 0.01, "\(style) at the default size")
        }
    }

    func testTheWeightAxisIsApplied() {
        func width(_ weight: BloemWeight) -> CGFloat {
            ("Playback history" as NSString).size(withAttributes: [.font: BloemFont.unscaled(size: 16, weight: weight)]).width
        }
        XCTAssertLessThan(width(.regular), width(.medium))
        XCTAssertLessThan(width(.medium), width(.semibold))
    }

    func testFiguresAreTabular() {
        for weight in [BloemWeight.regular, .medium, .semibold] {
            let font = BloemFont.unscaled(size: 16, weight: weight)
            func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
            XCTAssertEqual(width("1111"), width("0000"), accuracy: 0.01, "a 1 is as wide as a 0 at weight \(weight.rawValue)")
            XCTAssertEqual(width("1111"), width("8888"), accuracy: 0.01)
        }
    }

    func testTheLineHeightIsTheStylesAndFollowsDynamicType() {
        for style in BloemTextStyle.allCases {
            let font = BloemFont.uiFont(style)
            let total = font.lineHeight + BloemFont.lineSpacing(style, font: font)
            XCTAssertEqual(total, max(style.lineHeight, font.lineHeight), accuracy: 0.6, "\(style) line height")
        }
        let normal = BloemFont.uiFont(.bodyLarge, category: .large)
        let larger = BloemFont.uiFont(.bodyLarge, category: .accessibilityExtraLarge)
        XCTAssertGreaterThan(larger.pointSize, normal.pointSize * 1.5)
    }
}
