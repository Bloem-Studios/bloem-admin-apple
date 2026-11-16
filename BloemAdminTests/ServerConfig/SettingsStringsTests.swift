import XCTest
@testable import BloemAdmin

/// Every user-facing literal of the Settings pages has a `Localizable.xcstrings` entry, and none breaks
/// the copy rules: sentence case is checked on the catalogue itself, and no label, button or caption ends
/// in a full stop or an exclamation mark.
final class SettingsStringsTests: XCTestCase {
    private func catalogKeys() throws -> Set<String> {
        let url = SourceTree.root.appendingPathComponent("BloemAdmin/Localizable.xcstrings")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return Set(try XCTUnwrap(root["strings"] as? [String: Any]).keys)
    }

    private static let literal = #""((?:[^"\\]|\\.)*)""#

    /// The plain literals the Settings sources hand to `String(localized:)`, `Text`, `Label`, `Button`,
    /// `Toggle`, `LabeledContent`, `TextField`, `ContentUnavailableView`, `title:`, `help:`, `footer:`,
    /// `summary:`, `unit:` and the catalogue's own `SettingSpec`, `SettingChoice` and `SettingsSection`.
    private func settingsLiterals() throws -> Set<String> {
        let lit = Self.literal
        let patterns = [
            #"String\(localized:\s*"# + lit, #"\bText\(\s*"# + lit, #"\bLabel\(\s*"# + lit, #"\bButton\(\s*"# + lit,
            #"\bToggle\(\s*"# + lit, #"LabeledContent\(\s*"# + lit, #"\bTextField\(\s*"# + lit,
            #"ContentUnavailableView\(\s*"# + lit, #"\bhelp:\s*"# + lit, #"\bfooter:\s*"# + lit,
            #"\bsummary:\s*"# + lit, #"\bunit:\s*"# + lit, #"SettingSpec\(\s*"[^"]+",\s*"# + lit,
            #"SettingChoice\(\s*"[^"]*",\s*"# + lit, #"SettingsSection\(\s*"# + lit,
        ].map { try! NSRegularExpression(pattern: $0) }
        var found = Set<String>()
        for file in try SourceTree.appSources() where file.path.hasPrefix("ServerConfig/") && !file.path.hasSuffix("UITestFixture.swift") {
            let text = file.lines.joined(separator: "\n")
            for pattern in patterns {
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    let value = String(text[range])
                    if !value.contains("\\(") && !value.hasPrefix("settings.") && !value.hasPrefix("setting.") { found.insert(value) }
                }
            }
        }
        return found
    }

    func testEveryPlainSettingsLiteralIsInTheCatalog() throws {
        let literals = try settingsLiterals()
        XCTAssertGreaterThan(literals.count, 150, "the scanner should see the pages' strings")
        let missing = literals.subtracting(try catalogKeys()).sorted()
        XCTAssertEqual(missing, [], "Settings strings without a Localizable.xcstrings entry")
    }

    func testTheFormattedSettingsPhrasesAreInTheCatalog() throws {
        let keys = try catalogKeys()
        for key in [
            "Saved %@", "Needed for %@", "Up %@", "%lld unsaved", "Use %lld or more", "Use %lld or less",
            "Restart requested. %lld streams were told", "Settings changed on %@", "Last failure: %@",
        ] {
            XCTAssertTrue(keys.contains(key), "missing catalog key: \(key)")
        }
    }

    func testNoVisibleSettingsLiteralEndsInAFullStopOrExclamationMark() throws {
        let offenders = try settingsLiterals().filter { $0.hasSuffix(".") || $0.hasSuffix("!") || $0.contains("!") }.sorted()
        // "Applies: %@. " is joined to the confirmation text and never stands alone.
        XCTAssertEqual(offenders, [], "copy rules: no trailing periods, no exclamation marks")
    }
}
