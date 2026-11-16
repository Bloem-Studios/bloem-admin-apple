import XCTest
@testable import BloemAdmin

/// Every user-facing string of the dashboard has a `Localizable.xcstrings` entry, and the catalog
/// keeps the plural forms of the counted phrases.
final class DashboardStringsTests: XCTestCase {
    private func catalogStrings() throws -> [String: Any] {
        let url = SourceTree.root.appendingPathComponent("BloemAdmin/Localizable.xcstrings")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    /// The plain literals (no interpolation) the dashboard sources pass to `String(localized:)`,
    /// `Text`, `Label`, `Button`, `title:` and `actionTitle:`.
    private func dashboardLiterals() throws -> Set<String> {
        let pattern = try NSRegularExpression(
            pattern: #"(?:String\(localized:\s*|Text\(|Label\(|Button\(|ContentUnavailableView\(|title:\s*|actionTitle:\s*)"((?:[^"\\]|\\.)*)""#
        )
        var found = Set<String>()
        for file in try SourceTree.appSources() where file.path.hasPrefix("Dashboard/") {
            let text = file.lines.joined(separator: "\n")
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let literal = String(text[range])
                if !literal.contains("\\(") && !literal.hasPrefix("dashboard-") { found.insert(literal) }
            }
        }
        return found
    }

    func testEveryPlainDashboardLiteralIsInTheCatalog() throws {
        let keys = Set(try catalogStrings().keys)
        let literals = try dashboardLiterals()
        XCTAssertGreaterThan(literals.count, 60, "the scanner should see the dashboard's strings")
        let missing = literals.subtracting(keys).sorted()
        XCTAssertEqual(missing, [], "dashboard strings without a Localizable.xcstrings entry")
    }

    func testTheCountedPhrasesKeepTheirPluralForms() throws {
        let strings = try catalogStrings()
        for key in ["%lld sessions", "%lld files", "%lld warnings", "+%lld more active streams", "%lld plays · %@", "%@ · %lld paths"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let en = try XCTUnwrap((entry["localizations"] as? [String: Any])?["en"] as? [String: Any], key)
            let plural = try XCTUnwrap((en["variations"] as? [String: Any])?["plural"] as? [String: Any], key)
            XCTAssertNotNil(plural["one"], key)
            XCTAssertNotNil(plural["other"], key)
        }
    }

    func testTheFormattedDashboardPhrasesAreInTheCatalog() throws {
        let keys = Set(try catalogStrings().keys)
        for key in [
            "Sampled %@", "Last sample %@", "CPU %lld%%", "Memory %@ / %@", "Network %@/s ↓ / %@/s ↑",
            "%lld%% played", "%lld%% completed", "%@ Mbps", "Show chart for %@", "Show values for %@",
            "No playback in %@", "Latest %@ · Peak %@ · Lowest %@", "Total %@", "%@. Latest %@, peak %@, lowest %@.",
            "Egress over %@, in megabits per second", "Concurrent streams over %@",
            "Playback sessions per hour over %@, by play method", "Playback sessions per day over %@, by play method",
            "Busiest hour starts at %@ with %@", "Busiest day is %@ with %@", "%@. %@ in total. %@. %@.",
            "Direct play %@, direct stream %@, transcode %@", "%lld min ago", "%lld h ago", "%lld d ago",
        ] {
            XCTAssertTrue(keys.contains(key), "missing catalog key: \(key)")
        }
    }

    func testTheExistingCatalogEntriesWereNotRewritten() throws {
        let strings = try catalogStrings()
        for key in ["Dashboard", "Total items", "Watch providers", "Server health", "Connection lost"] {
            XCTAssertNotNil(strings[key], "\(key) was removed from the catalog")
        }
    }
}
