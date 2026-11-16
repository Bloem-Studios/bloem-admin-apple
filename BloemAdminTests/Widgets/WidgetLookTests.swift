import SwiftUI
import XCTest
@testable import BloemAdmin

/// The widgets' look: the staff look's colours at 4.5:1 on the card, the icons in the extension's own
/// catalog, and the font and keychain configuration the extension needs.
final class WidgetLookTests: XCTestCase {
    private func linear(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private func luminance(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testEveryTextColourReachesFourPointFiveOnTheCard() {
        for (name, values) in [("dark", WidgetPalette.darkValues), ("light", WidgetPalette.lightValues)] {
            for (role, colour) in [
                ("text", values.text), ("muted", values.muted), ("accent", values.accent),
                ("ok", values.ok), ("warning", values.warning), ("danger", values.danger),
            ] {
                XCTAssertGreaterThanOrEqual(ratio(colour, values.card), 4.5, "\(role) on the \(name) card")
            }
        }
    }

    func testEveryTextColourReachesFourPointFiveOnThePageToo() {
        // The widget is the app's page (`canvas`), and a few labels sit directly on it.
        for (name, values) in [("dark", WidgetPalette.darkValues), ("light", WidgetPalette.lightValues)] {
            for (role, colour) in [
                ("text", values.text), ("muted", values.muted), ("accent", values.accent),
                ("ok", values.ok), ("warning", values.warning), ("danger", values.danger),
            ] {
                XCTAssertGreaterThanOrEqual(ratio(colour, values.canvas), 4.5, "\(role) on the \(name) canvas")
            }
        }
    }

    func testThePageAndTheCardAreTheAppsSurfaces() {
        XCTAssertEqual(WidgetPalette.darkValues.canvas, 0x141417)
        XCTAssertEqual(WidgetPalette.lightValues.canvas, 0xF6F6F8)
        XCTAssertNotEqual(WidgetPalette.dark.canvas, WidgetPalette.dark.card, "the cards stand out from the page")
        XCTAssertNotEqual(WidgetPalette.light.canvas, WidgetPalette.light.card)
    }

    func testThePaletteIsTheSpecsTokens() {
        XCTAssertEqual(WidgetPalette.darkValues.card, 0x1C1C20)
        XCTAssertEqual(WidgetPalette.lightValues.card, 0xFFFFFF)
        XCTAssertEqual(WidgetPalette.darkValues.accent, 0xFA6400)
        XCTAssertEqual(WidgetPalette.lightValues.accent, 0xA04000)
        XCTAssertEqual(WidgetPalette.dark.chart.count, 5)
        XCTAssertEqual(WidgetPalette.of(.dark), .dark)
        XCTAssertEqual(WidgetPalette.of(.light), .light)
    }

    func testEveryWidgetIconIsInTheExtensionsCatalogAndIsALucideIconTheAppAlsoShips() throws {
        let widgetCatalog = SourceTree.root.appendingPathComponent("BloemAdminWidgets/Icons.xcassets")
        let shipped = Set(try FileManager.default.contentsOfDirectory(atPath: widgetCatalog.path)
            .filter { $0.hasSuffix(".imageset") }.map { String($0.dropLast(".imageset".count)) })
        for icon in WidgetIcon.allCases {
            XCTAssertTrue(shipped.contains(icon.assetName), "\(icon.assetName) is missing from BloemAdminWidgets/Icons.xcassets")
            XCTAssertTrue(BloemIcon.allCases.contains { $0.rawValue == icon.rawValue }, "\(icon.rawValue) is not one of the app's Lucide icons")
        }
        XCTAssertTrue(shipped.isSubset(of: Set(WidgetIcon.allCases.map(\.assetName) + ["lucide.radio", "lucide.triangle-alert"])), "an icon nothing draws")
    }

    func testTheExtensionAndTheAppRegisterThePlusJakartaSansFont() throws {
        let yml = try String(contentsOf: SourceTree.root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertEqual(yml.components(separatedBy: "- PlusJakartaSans-Variable.ttf").count - 1, 2, "UIAppFonts of the app and of the extension")
        XCTAssertTrue(yml.contains("- path: BloemAdmin/Resources/Fonts/PlusJakartaSans-Variable.ttf"), "the extension bundles the font")
        let plist = try String(contentsOf: SourceTree.root.appendingPathComponent("BloemAdminWidgets/Info.plist"), encoding: .utf8)
        XCTAssertTrue(plist.contains("PlusJakartaSans-Variable.ttf"))
    }

    func testTheKeychainGroupAndLiveActivitiesAreDeclared() throws {
        let yml = try String(contentsOf: SourceTree.root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertEqual(yml.components(separatedBy: "$(AppIdentifierPrefix)com.bloemstudios.admin.shared").count - 1, 3, "app, widget extension and notification extension entitlements")
        XCTAssertTrue(yml.contains("NSSupportsLiveActivities: true"))
        XCTAssertEqual(yml.components(separatedBy: "BloemKeychainGroupPrefix: $(AppIdentifierPrefix)").count - 1, 3)
    }

    func testTheWidgetsNeverUseASystemFontOrASymbolOrAnEmoji() throws {
        // LookGuardTests scans the whole app; this adds the widget extension's own folder and checks emoji.
        let files = try SourceTree.sources(in: "BloemAdminWidgets") + SourceTree.sources(in: "BloemAdmin/Shared/Widgets")
        for file in files {
            for (index, line) in file.lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                XCTAssertFalse(line.unicodeScalars.contains { $0.properties.isEmojiPresentation }, "\(file.path):\(index + 1) has an emoji")
                XCTAssertFalse(line.contains("systemName") || line.contains(".font(.system"), "\(file.path):\(index + 1)")
            }
        }
    }

    func testCopyFollowsTheSpec() throws {
        // Sentence case, no trailing period on short strings; admin widgets say Silo.
        let files = try SourceTree.sources(in: "BloemAdmin/Shared/Widgets") + SourceTree.sources(in: "BloemAdminWidgets")
        for file in files {
            for (index, line) in file.lines.enumerated() {
                for pattern in [#"Text\("([^"]*)\.\"\)"#, #"Text\(verbatim: "([^"]*)\.\""#] {
                    if let match = line.range(of: pattern, options: .regularExpression) {
                        XCTFail("\(file.path):\(index + 1) ends a short string with a period: \(line[match])")
                    }
                }
                XCTAssertFalse(line.contains("!\")"), "\(file.path):\(index + 1) has an exclamation mark")
            }
        }
        XCTAssertEqual(WidgetSamples.entry().statusModel.title, "All servers")
    }

    // MARK: The app tag (maintainer, 2026-11-16: "make the widgets list the app they belong to")

    func testTheAppTagNameIsTheHomeScreenName() throws {
        let yml = try String(contentsOf: SourceTree.root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("CFBundleDisplayName: \(WidgetApp.name)"), "the tag says what is under the app's icon")
        XCTAssertEqual(WidgetApp.name, "Bloem Admin")
    }

    func testTheAppMarkIsATemplateImageAtSixteenPointsInBothAppAndExtension() throws {
        let folder = SourceTree.root.appendingPathComponent("BloemAdmin/Shared/Widgets/Marks.xcassets/bloem.admin-mark.imageset")
        let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("Contents.json"))) as? [String: Any]
        let properties = try XCTUnwrap(contents?["properties"] as? [String: Any])
        XCTAssertEqual(properties["template-rendering-intent"] as? String, "template", "the mark takes the colour its widget gives it")
        for (scale, pixels) in [("2x", 32), ("3x", 48)] {
            let image = try XCTUnwrap(UIImage(contentsOfFile: folder.appendingPathComponent("mark@\(scale).png").path), scale)
            XCTAssertEqual(Int(image.size.width * image.scale), pixels)
            XCTAssertEqual(image.size.width, image.size.height, "square")
            XCTAssertEqual(image.cgImage?.alphaInfo == CGImageAlphaInfo.none, false, "the drawing is the alpha")
        }
        // The catalog sits under BloemAdmin/Shared, which the app and the widget extension both compile.
        XCTAssertNotNil(UIImage(named: "bloem.admin-mark"), "the app bundle has it too: the render tests draw the widgets in the app")
        let yml = try String(contentsOf: SourceTree.root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("- path: BloemAdmin/Shared"))
    }

    func testTheTagIsIdentificationNotContentSoItNeverTakesTheAccentOrTheTally() throws {
        let parts = try XCTUnwrap(SourceTree.sources(in: "BloemAdmin/Shared/Widgets/Views").first { $0.path == "WidgetParts.swift" })
        var inTag = false
        for (index, line) in parts.lines.enumerated() {
            if line.hasPrefix("struct WidgetAppMark") || line.hasPrefix("struct WidgetAppTag") { inTag = true }
            else if line.hasPrefix("struct ") || line.hasPrefix("enum ") || line.hasPrefix("extension ") { inTag = false }
            guard inTag, !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            XCTAssertFalse(line.contains("palette.accent") || line.contains("palette.tally") || line.contains("WidgetTallyDot"), "WidgetParts.swift:\(index + 1)")
        }
        XCTAssertTrue(parts.lines.contains { $0.contains("WidgetAppMark") && $0.contains("struct") })
    }

    func testEveryGalleryNameAndDescriptionStartsWithTheAppsName() throws {
        let files = try SourceTree.sources(in: "BloemAdminWidgets").filter { ["SiloWidgets.swift", "NowPlayingControl.swift", "RequestsWaitingControl.swift"].contains($0.path) }
        XCTAssertEqual(files.count, 3)
        var strings = 0
        for file in files {
            for (index, line) in file.lines.enumerated() {
                for call in [".configurationDisplayName(", ".displayName(", ".description("] where line.contains(call) {
                    strings += 1
                    XCTAssertTrue(line.contains("\(call)\"\(WidgetApp.name)"), "\(file.path):\(index + 1) does not start with the app's name: \(line)")
                }
            }
        }
        XCTAssertEqual(strings, 14, "five widgets and two controls, each with a name and a description")
    }

    func testTheDesignNotesNameTheAdminWidgets() throws {
        let copy = try String(contentsOf: SourceTree.root.appendingPathComponent("docs/design.md"), encoding: .utf8)
        for name in ["Server status", "Now playing", "Requests", "Libraries and scans", "Nodes and resources"] {
            XCTAssertTrue(copy.contains(name), name)
        }
    }
}
