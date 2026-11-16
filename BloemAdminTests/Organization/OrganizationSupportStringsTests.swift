import XCTest

/// The organization support pages' words are in the string catalog, so a translation pass finds them without
/// rebuilding with `SWIFT_EMIT_LOC_STRINGS` first.
final class OrganizationSupportStringsTests: XCTestCase {
    func testTheSupportWordsAreCatalogBacked() throws {
        let url = SourceTree.root.appendingPathComponent("BloemAdmin/Localizable.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = Set(try XCTUnwrap(root["strings"] as? [String: Any]).keys)
        let expected = [
            // Person page
            "Password", "Email a reset link", "Create a reset link to hand over", "Email a reset link to %@?",
            "Create a reset link for %@?", "Reset link ready", "Signed in", "Sign out everywhere", "Sign %@ out everywhere?",
            "Sign out of this session", "Devices", "Sign out of this device", "Add profile", "Rename profile", "Clear PIN",
            "Remove profile", "Change %@", "Main profile", "PIN set", "Who you can help",
            "Give this link to %@ yourself. It works once, until %@. Anyone who has it can choose their password, so send it to them only. It isn't shown again.",
            "A reset email is on its way to %@. The link works for 24 hours.",
            "Signed out everywhere: %lld sessions ended", "PIN cleared on %@. They choose a new one on the profile.",
            // Refusals
            "This person is the organization's owner. Only the platform operator can help the owner.",
            "This person is an administrator. Only the organization's owner can help another administrator.",
            "You can't do this to your own account. Change your own password or sign out in the app.",
            "This is a server operator's account. It can't be changed from an organization.",
            "This server can't send email. Create a link to hand over instead.",
            "Too many support actions in a short time. Try again in %lld minutes.",
            // Streams
            "Streams", "Nothing playing", "Stop stream", "Stop %@'s stream of %@?", "Message sent to %@",
            "Stream stopped. The player wasn't told, so it may play what it already loaded.",
            // Support access
            "Support access", "Support access", "End access", "End support access to %@?", "%@ left", "Open for support",
            "Why are you opening %@?", "%lld of 10 to 500 characters. %@'s administrators see this reason in Activity, with every change you make.",
            "Support access to this organization has ended. To keep helping, open it again with a new reason.",
            "By Platform support", "Reason: %@", "Platform support opened this organization",
        ]
        let missing = expected.filter { !keys.contains($0) }
        XCTAssertEqual(missing, [], "missing catalog keys")
    }
}
