import XCTest
@testable import BloemAdmin

/// Every string the Libraries page shows has a `Localizable.xcstrings` entry, so a translation pass finds them
/// all without a build to discover them. Interpolations are written as the catalog spells them: `%@` for text and
/// `%lld` for whole numbers.
final class LibraryStringsTests: XCTestCase {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Libraries
        .deletingLastPathComponent()  // BloemAdminTests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("BloemAdmin/Localizable.xcstrings")

    private func catalogKeys() throws -> Set<String> {
        let data = try Data(contentsOf: Self.catalogURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(try XCTUnwrap(root["strings"] as? [String: Any]).keys)
    }

    static let keys = [
        // Page and menu
        "Libraries", "Media libraries, paths, scanning, and catalog import.",
        // Library rows
        "1 path", "%lld paths", "Enabled", "Disabled", "%@ · %@ · %@", "Last scanned %@", "Never scanned",
        "No libraries configured", "Library %@",
        // Scan warning
        "The scan found no media files", "A library folder cannot be reached", "Since %@",
        // Scan feedback
        "Queued", "Running", "Completed", "Failed", "Stopped", "Scan: %@", "Scan: %@, %lld scans", "Scan: %@, %lld more queued",
        "Last scan: %@", "Last scan: %@, %@", "New %lld · Updated %lld · Missing %lld · Errors %lld",
        "Recent scans", "No scans yet", "Scan results are not available: %@", "%@: %@",
        "Autoscan", "Created", "Updated", "Manual", "Scheduled", "File change",
        // Actions
        "Scan", "Stop", "Check the mount", "Refresh metadata", "Refresh missing metadata", "Refresh all metadata", "Cancel refresh",
        "This server cannot start or stop scans",
        "Stop scans", "Keep scanning", "Stop scans of %@?",
        "This stops the scans of %@ that are queued or running. You can start a new scan at any time.",
        "Refresh all metadata for %@?",
        "Every item in %@ is fetched again from its metadata providers. Large libraries can take hours. Locked fields and artwork stay as they are.",
        "Stopped the scan of %@", "Stopped %lld scans of %@", "No scans of %@ were queued or running",
        // Mount check
        "Checking the mount", "The mount is reachable", "The mount cannot be reached", "The mount is reachable but looks empty",
        "%@: not reachable", "%@: not reachable, %@", "%@: reachable but empty",
        // Metadata refresh
        "Metadata refresh: %@", "Last metadata refresh: %@", "Last metadata refresh: %@, %@",
        "Canceling", "Canceled", "items", "%lld of %lld %@", "%lld refreshed", "%lld refreshed, %lld failed",
        // Errors
        "Could not load libraries. Check the connection and try again.",
        "Could not scan %@: %@. Try again in a moment.", "Could not stop the scans of %@: %@. Try again.",
        "Could not check the mount of %@: %@. Try again.",
        "Could not refresh the metadata of %@: %@. Wait for the running refresh to finish, or try again.",
        "Could not cancel the metadata refresh of %@: %@. Try again.",
        "The server did not answer", "The scan results could not be read", "The metadata refreshes could not be read",
    ]

    func testEveryLibrariesStringIsInTheCatalog() throws {
        let catalog = try catalogKeys()
        XCTAssertEqual(Self.keys.filter { !catalog.contains($0) }, [], "missing catalog keys")
    }

    func testLibrariesStringsFollowTheCopyRules() {
        for key in Self.keys {
            XCTAssertFalse(key.contains("!"), "no exclamation marks: \(key)")
        }
        // Titles, labels, buttons and captions carry no trailing period; only sentences (messages) do.
        let labels = [
            "Libraries", "Scan", "Stop", "Check the mount", "Refresh metadata", "Refresh missing metadata", "Refresh all metadata",
            "Cancel refresh", "Stop scans", "Keep scanning", "Recent scans", "No scans yet", "Never scanned",
            "The scan found no media files", "A library folder cannot be reached", "The mount is reachable",
            "This server cannot start or stop scans",
        ]
        for label in labels {
            XCTAssertFalse(label.hasSuffix("."), "no trailing period on a label: \(label)")
        }
    }
}
