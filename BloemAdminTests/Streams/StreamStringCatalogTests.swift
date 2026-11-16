import XCTest
@testable import BloemAdmin

/// The wording the Now playing rows use must be in the string catalog, so a translation pass finds it.
final class StreamStringCatalogTests: XCTestCase {
    func testNowPlayingStringsAreInCatalog() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BloemAdmin/Localizable.xcstrings")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = Set(try XCTUnwrap(root["strings"] as? [String: Any]).keys)
        for key in [
            "Playing", "Paused", "Direct play", "Remux", "Direct stream", "Transcode", "Unknown", "Direct", "Copy",
            "Video: %@", "Audio: %@", "HW %@", "SW", "HW/SW pending", "HW/SW unknown", "Audio transcode",
            "HW Tone map", "SW Tone map", "%@ / %@", "%@ left", "%@ of %@, %@ left", "at %@",
            "Details shown", "Details hidden", "Shows the details", "Hides the details",
            "Method", "Video", "Audio", "Container", "Source bitrate", "Stream bitrate", "Audio track", "Transcoder",
            "Playing node", "Client", "Network", "Client IP", "Started", "Last update",
            "Unknown source", "Output → %@", "Transcoding", "No video conversion", "No audio conversion",
            "Copied without re-encoding", "Local", "Remote", "Local server", "%@: %@", "Proxy", "Server", "Node",
            "Action in progress", "Actions for %@", "Message sent", "Dismiss", "Resume", "Pause", "Stop", "Message", "Terminate",
        ] {
            XCTAssertTrue(keys.contains(key), "missing catalog key: \(key)")
        }
    }
}
