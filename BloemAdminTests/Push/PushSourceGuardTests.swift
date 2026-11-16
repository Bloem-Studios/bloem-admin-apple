import XCTest
@testable import BloemAdmin

/// What the notification service extension is allowed to touch, and the project settings push depends on.
/// These read the sources, as the other guards do.
final class PushSourceGuardTests: XCTestCase {
    /// The extension sees the display token and nothing that can sign in, show UI or reach the app's own store.
    private let forbiddenInTheExtension = [
        "ServerCredentials", "CredentialStoring", "KeychainCredentialStore", "ServerStore", "AdminSessionState",
        "accessToken", "refreshToken", "APIClient", "UIKit", "SwiftUI", "WidgetKit", "UIApplication",
        "SharedCredential", "UserDefaults",
    ]

    private func code(_ lines: [String]) -> [(Int, String)] {
        lines.enumerated().map { ($0.offset + 1, $0.element.components(separatedBy: "//").first ?? $0.element) }
    }

    private func extensionSources() throws -> [(path: String, lines: [String])] {
        var files: [(String, [String])] = []
        for file in try SourceTree.sources(in: "BloemAdmin/Push/Core") { files.append(("BloemAdmin/Push/Core/" + file.path, file.lines)) }
        for file in try SourceTree.sources(in: "BloemAdminNotificationService") { files.append(("BloemAdminNotificationService/" + file.path, file.lines)) }
        for path in ["Networking/API/PushDisplayAPI.swift", "Networking/API/APIPath.swift"] {
            let file = try XCTUnwrap(try SourceTree.appSources().first { $0.path == path })
            files.append(("BloemAdmin/" + path, file.lines))
        }
        return files
    }

    func testTheExtensionNeverTouchesASignInOrAScreen() throws {
        let files = try extensionSources()
        XCTAssertGreaterThan(files.count, 6, "the scan should see the shared core, the client and the extension")
        var offenders: [String] = []
        for (path, lines) in files {
            for (number, line) in code(lines) {
                for word in forbiddenInTheExtension where line.contains(word) {
                    offenders.append("\(path):\(number): \(word)")
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testTheExtensionSendsOnlyTheDisplayToken() throws {
        let client = try XCTUnwrap(try SourceTree.appSources().first { $0.path == "Networking/API/PushDisplayAPI.swift" })
        let bearers = client.lines.filter { $0.contains("Bearer") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        XCTAssertEqual(bearers.count, 1)
        XCTAssertTrue(bearers[0].contains("token)"), "the bearer is the token a caller hands in")
    }

    func testTheStoredTokenIsReadableAfterFirstUnlockAndNotMoreOpenThanThat() throws {
        let store = try XCTUnwrap(try SourceTree.sources(in: "BloemAdmin/Push/Core").first { $0.path == "PushRegistration.swift" })
        let text = store.lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"))
        XCTAssertFalse(text.contains("kSecAttrAccessibleAlways"))
        XCTAssertFalse(text.contains("kSecAttrSynchronizable"), "never in iCloud keychain")
    }

    func testTheBackgroundAlertCheckStillTouchesNoSignIn() throws {
        // The registrar signs in; the local server-down check never does (AlertSourceGuardTests keeps the rest).
        let runner = try XCTUnwrap(try SourceTree.sources(in: "BloemAdmin/Alerts").first { $0.path == "AlertRunner.swift" })
        for (number, line) in code(runner.lines) {
            XCTAssertFalse(line.contains("PushRuntime") || line.contains("ServerStore"), "AlertRunner.swift:\(number)")
        }
    }

    // MARK: The project

    private func projectYAML() throws -> String {
        try String(contentsOf: SourceTree.root.appendingPathComponent("project.yml"), encoding: .utf8)
    }

    func testTheExtensionHasTheBundleIdTheConsoleRegistered() throws {
        let yaml = try projectYAML()
        XCTAssertTrue(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.bloemstudios.admin.NotificationService"))
        XCTAssertTrue(yaml.contains("NSExtensionPointIdentifier: com.apple.usernotifications.service"))
        XCTAssertTrue(yaml.contains("NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).NotificationService"))
        XCTAssertTrue(yaml.contains("- target: BloemAdminNotificationService"), "the app embeds it")
    }

    func testTheExtensionSharesTheAppGroupAndKeychainGroupTheConsoleRegistered() throws {
        let yaml = try projectYAML()
        let section = try XCTUnwrap(yaml.components(separatedBy: "  BloemAdminNotificationService:\n").last?
            .components(separatedBy: "  BloemAdminTests:").first)
        XCTAssertTrue(section.contains("group.com.bloemstudios.admin"))
        XCTAssertTrue(section.contains("$(AppIdentifierPrefix)com.bloemstudios.admin.shared"))
        XCTAssertTrue(section.contains("APPLICATION_EXTENSION_API_ONLY: YES"))
        XCTAssertEqual(PushGroup.identifier, AppGroup.identifier)
        XCTAssertEqual(PushKeychain.groupSuffix, SharedKeychain.groupSuffix)
    }

    func testTheAppCanRegisterForPushInDebugAndRelease() throws {
        let yaml = try projectYAML()
        XCTAssertTrue(yaml.contains("aps-environment: $(APS_ENVIRONMENT)"))
        XCTAssertTrue(yaml.contains("APS_ENVIRONMENT: development"))
        XCTAssertTrue(yaml.contains("APS_ENVIRONMENT: production"))
        XCTAssertTrue(yaml.contains("BloemAPSEnvironment: $(APS_ENVIRONMENT)"))
    }

    func testTheGeneratedFilesCarryWhatPushNeeds() throws {
        func text(_ path: String) throws -> String {
            try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8)
        }
        let entitlements = try text("BloemAdmin/BloemAdmin.entitlements")
        XCTAssertTrue(entitlements.contains("aps-environment"))
        XCTAssertTrue(entitlements.contains("group.com.bloemstudios.admin"))
        let info = try text("BloemAdmin/Info.plist")
        XCTAssertTrue(info.contains("BloemAPSEnvironment"))
        let extensionInfo = try text("BloemAdminNotificationService/Info.plist")
        XCTAssertTrue(extensionInfo.contains("com.apple.usernotifications.service"))
        XCTAssertTrue(extensionInfo.contains("BloemKeychainGroupPrefix"))
        let extensionEntitlements = try text("BloemAdminNotificationService/BloemAdminNotificationService.entitlements")
        XCTAssertFalse(extensionEntitlements.contains("aps-environment"), "an extension rides its app's topic")
    }

    func testTheDesignNotesListEveryPushKindAndItsLockScreenText() throws {
        let spec = try String(
            contentsOf: SourceTree.root.appendingPathComponent("docs/design.md"), encoding: .utf8
        )
        for kind in PushKind.allCases { XCTAssertTrue(spec.contains("`\(kind.rawValue)`"), kind.rawValue) }
        for kind in PushKind.allCases {
            XCTAssertTrue(spec.contains("\"\(kind.lockScreenText)\""), "the lock-screen text of \(kind.rawValue) is the design notes'")
        }
    }
}
