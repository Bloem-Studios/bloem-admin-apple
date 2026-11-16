import XCTest
@testable import BloemAdmin

/// Guards the string catalog against drifting behind the views again: every
/// user-facing literal the newer screens (Dashboard, Logs, Tenants,
/// Invitations) and the formerly hard-coded session/gate messages use must
/// have a `Localizable.xcstrings` entry, so a translation pass never has to
/// rebuild with `SWIFT_EMIT_LOC_STRINGS` first to discover them.
final class StringCatalogTests: XCTestCase {

    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // App
        .deletingLastPathComponent()  // BloemAdminTests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("BloemAdmin/Localizable.xcstrings")

    private func catalogKeys() throws -> Set<String> {
        let data = try Data(contentsOf: Self.catalogURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        return Set(strings.keys)
    }

    func testFormerlyHardCodedMessagesAreCatalogBacked() throws {
        let keys = try catalogKeys()
        for key in [
            "No admin access",
            "Sign in was cancelled.",
            "%@ couldn't be reached. Check the address and your connection.",
            "Session changed before sign in completed."
        ] {
            XCTAssertTrue(keys.contains(key), "missing catalog key: \(key)")
        }
    }

    func testOAuthSignInStringsAreInCatalog() throws {
        let keys = try catalogKeys()
        for key in [
            "This account isn't allowed to sign in to this server.",
            "No account on this server uses that sign-in. Ask the server's owner for an invitation.",
            "An account with that email already exists. Sign in with its password instead.",
            "That sign-in is linked to a different account.",
            "This account is disabled.",
            "%@ isn't available right now. Try again later.",
            "The sign-in took too long or was interrupted. Try again.",
            "Sign-in didn't finish. Try again.",
            "The sign-in response didn't come from this server. Try again.",
            "Install or turn on a web browser to sign in with %@",
            "This server's sign-in options aren't available in this app.",
            "This server needs a newer version of Bloem Admin.",
            "Sign in with %@", "Continue", "Change server", "Checking sign-in options…",
            "Could not save this server on this device."
        ] {
            XCTAssertTrue(keys.contains(key), "missing catalog key: \(key)")
        }
    }

    func testInvitationDeliveryStringsAreInCatalog() throws {
        let keys = try catalogKeys()
        for key in [
            "The email may not have been delivered. Share the link yourself.",
            "Email delivery unconfirmed",
            "Link invitation"
        ] {
            XCTAssertTrue(keys.contains(key), "missing catalog key: \(key)")
        }
    }

    func testNewerViewStringsAreInCatalog() throws {
        let keys = try catalogKeys()
        for key in [
            // Dashboard
            "Dashboard", "Total items", "Active streams", "Watch providers", "Server health",
            "No watch providers registered", "Server statistics couldn't be loaded. Try again.",
            // Logs
            "Logs", "Level", "Search messages", "No log entries",
            "This server has no operational log entries", "No log entries match the selected filters",
            "· User %@", "User %@", "Logs couldn't be loaded. Try again.", "More log entries couldn't be loaded. Try again.",
            // Tenants
            "Tenants", "No organizations", "No members", "Suspended", "Suspended: %@",
            "%lld / %lld slots", "%lld slots used", "0 / %lld slots", "No slot data",
            "1 transcode", "%lld transcodes", "No transcode limit set",
            "Organizations couldn't be loaded. Try again.", "Members couldn't be loaded. Try again.",
            // Invitations
            "Invitations", "No invitations", "Invite a new user by email", "Invite user",
            "Revoke invitation", "Revoke the invitation to %@? This cannot be undone.",
            "Invitation created", "Invitation email sent", "Invitation email not sent",
            "Copy link", "Share link", "Invite link", "Done",
            "Invitations couldn't be loaded. Try again.", "The invitation couldn't be sent. Try again.",
            "The invitation couldn't be resent. Try again.", "The invitation couldn't be revoked. Try again."
        ] {
            XCTAssertTrue(keys.contains(key), "missing catalog key: \(key)")
        }
    }

    func testUserEditorStringsAreInCatalog() throws {
        let keys = try catalogKeys()
        for key in [
            "Current values", "%@ current values", "Review current values", "Inherit",
            "This user changed on the server after you opened it. Your edit is kept.",
            "This user changed on %@ after you opened it. Your edit is kept.",
            "Revoked %lld sessions", "Profiles: %@", "%@ · Last seen %@", "Unknown device", "Current",
        ] {
            XCTAssertTrue(keys.contains(key), "missing catalog key: \(key)")
        }
    }

    func testTenantSummaryTextsStillRenderInSourceLanguage() throws {
        let json = """
        {"id":"t-1","tenant_id":"t-1","name":"Acme","frozen":false,
         "limits":{"slots":10,"transcodes":1},"usage":{"slots_used":7}}
        """
        let tenant = try JSONDecoder().decode(Tenant.self, from: Data(json.utf8))
        XCTAssertEqual(tenant.slotsUsageText, "7 / 10 slots")
        XCTAssertEqual(tenant.transcodeLimitText, "1 transcode")
    }

    func testShellStringsAreInCatalog() throws {
        let keys = try catalogKeys()
        var required = [
            "Open menu", "Search admin sections", "Close search", "Clear search", "Search",
            "Admin sections", "No matching admin sections", "1 admin section", "%lld admin sections",
            "1 match", "%lld matches", "Change server context from %@", "All servers", "Manage servers",
            "App settings", "Checking access", "Sign in", "No access", "Can't reach server",
            "Signed in", "Signed out", "Forget credentials", "Remove server", "Remove %@?",
            "Forget credentials for %@?", "No servers",
        ]
        // Every page's name, group and description, as the shell and page search show them.
        for page in AdminDestination.singleServer(tenantsVisible: true) {
            required.append(contentsOf: [
                String(describing: page.label.key), String(describing: page.pageDescription.key),
                String(describing: page.group.label.key),
            ])
        }
        for key in required {
            XCTAssertTrue(keys.contains(key), "missing catalog key: \(key)")
        }
    }
}
