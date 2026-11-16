import XCTest
@testable import BloemAdmin

/// Nothing platform-level is reachable from an organization, the pass never touches disk, and the words the pages use
/// are in the string catalog.
final class OrganizationBoundaryTests: XCTestCase {
    private func organizationSources() throws -> [SourceTree.File] {
        try SourceTree.appSources().filter { $0.path.hasPrefix("Organization/") }
    }

    func testTheScannerSeesTheOrganizationSources() throws {
        let paths = try organizationSources().map(\.path)
        XCTAssertTrue(paths.contains("Organization/OrganizationSession.swift"))
        XCTAssertTrue(paths.contains("Organization/OrganizationHost.swift"))
        XCTAssertGreaterThan(paths.count, 10)
    }

    func testOrganizationCodeNeverCallsAPlatformOrSiloAdminRoute() throws {
        let forbidden = [
            "tenants(", "tenantMembers(", "TenantsListView", "AdminTab", "serverStatus()", "adminStats(", "listSessions(",
            "terminateSession(", "users()", "createUser(", "requestServerRestart(", "/admin/platform", "/api/v2/admin",
        ]
        var offenders: [String] = []
        for file in try organizationSources() where file.path != "Organization/AdminContext.swift" {
            for (index, line) in file.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") { continue }
                for word in forbidden where line.contains(word) {
                    offenders.append("\(file.path):\(index + 1): \(word)")
                }
            }
        }
        // AdminContext.swift runs the gate's platform probe once, to learn platform authority; nothing else may.
        XCTAssertEqual(offenders, [])
    }

    func testThePassAndTheClaimLinkAreNeverWrittenToDiskOrLogged() throws {
        let forbidden = ["UserDefaults", "Keychain", "FileManager", "NSLog(", "print(", "Logger(", "os_log", "write(to:", "@AppStorage", "@SceneStorage", "UIPasteboard"]
        var offenders: [String] = []
        for file in try organizationSources() where file.path != "Organization/OrganizationUITestHost.swift" {
            for (index, line) in file.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") { continue }
                for word in forbidden where line.contains(word) {
                    offenders.append("\(file.path):\(index + 1): \(word)")
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testTheOrganizationCodeNeverShowsAClientAddress() throws {
        var offenders: [String] = []
        for file in try organizationSources() {
            for (index, line) in file.lines.enumerated() where line.lowercased().contains("clientip") || line.contains("ip_address") {
                offenders.append("\(file.path):\(index + 1)")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testTheMenuIsExactlyTheWebsOrganizationPagesInOrder() {
        XCTAssertEqual(
            OrganizationPage.offered(.none).map(\.title),
            ["Overview", "People", "Cohorts", "Access groups", "Libraries", "Invitations", "Access checks", "Activity"]
        )
        // The organization's own streams come second, after Overview, only on a server that serves them.
        XCTAssertEqual(
            OrganizationPage.offered(SupportCapabilities(streams: .init(list: true))).map(\.title),
            ["Overview", "Now playing", "People", "Cohorts", "Access groups", "Libraries", "Invitations", "Access checks", "Activity"]
        )
    }

    func testTheOrganizationsStreamsLeaveTheServersRoutingOut() throws {
        let sources = try organizationSources()
        let rows = sources.flatMap { file in file.lines.filter { $0.contains("StreamRowView(") }.map { (file.path, $0) } }
        XCTAssertFalse(rows.isEmpty, "the organization's streams reuse the platform's row")
        for (path, line) in rows {
            XCTAssertTrue(line.contains("showServerRouting: false"), "\(path) draws a stream row with the server's routing: \(line)")
        }
    }

    func testTheSupportAccessPageLivesOutsideTheOrganization() throws {
        // Listing every organization needs the platform pass: that code is the platform's, never the organization's.
        let paths = try SourceTree.appSources().map(\.path)
        XCTAssertTrue(paths.contains("SupportAccess/SupportAccessModel.swift"))
        XCTAssertFalse(paths.contains { $0.hasPrefix("Organization/") && $0.contains("SupportAccess") })
    }

    func testOrganizationStringsAreInCatalog() throws {
        let url = SourceTree.root.appendingPathComponent("BloemAdmin/Localizable.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = Set(try XCTUnwrap(root["strings"] as? [String: Any]).keys)
        for key in [
            "Overview", "People", "Cohorts", "Access groups", "Libraries", "Invitations",
            "Access checks", "Activity",
            "This organization is suspended. Contact the server owner.",
            "You no longer administer this organization",
            "You don't have access to this organization",
            "Choose another organization",
            "Someone else changed this just now. It has been reloaded; check it and try again.",
            "Library paused. Members can't use it until you restore it.",
            "Nobody was changed", "Some people were changed", "already had these settings",
            "No email was sent. Deliver this one-time link yourself. It works once and expires in 7 days; resending makes a fresh link and ends this one.",
            "Select all %lld", "Actions for %@", "What you can't do here",
        ] {
            XCTAssertTrue(keys.contains(key), "missing catalog key: \(key)")
        }
    }
}
