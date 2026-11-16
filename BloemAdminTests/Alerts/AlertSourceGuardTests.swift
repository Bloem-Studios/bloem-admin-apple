import XCTest

/// The background check and the snapshot must never touch a stored sign-in. The data widgets may read the
/// app's sign-in (the maintainer approved live data in widgets, 2026-11-15), but only through the three files named in
/// `signInFiles`, which read the shared keychain mirror and nothing else. These read the sources, as the
/// other guards do.
final class AlertSourceGuardTests: XCTestCase {
    /// The only widget files that handle a token: the mirror in the shared keychain group, the fetcher that
    /// uses it and the small API client that sends it.
    private let signInFiles: Set<String> = [
        "BloemAdmin/Shared/Widgets/WidgetCredentialMirror.swift",
        "BloemAdmin/Shared/Widgets/WidgetFetcher.swift",
        "BloemAdmin/Networking/API/WidgetServerAPI.swift",
    ]

    private let forbidden = [
        "Keychain", "CredentialStoring", "ServerCredentials", "accessToken", "refreshToken",
        "ServerStore", "AdminSessionState", "\"Authorization\"", "Bearer",
    ]

    private func files(under relativePath: String) throws -> [(String, String)] {
        let url = SourceTree.root.appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if !isDirectory.boolValue { return [(relativePath, try String(contentsOf: url, encoding: .utf8))] }
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
        return try walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
            .map { (String($0.path.dropFirst(SourceTree.root.path.count + 1)), try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testNothingTheBackgroundCheckOrAWidgetRunsReadsASignIn() throws {
        var checked = 0
        var offenders: [String] = []
        for root in ["BloemAdmin/Alerts", "BloemAdmin/Shared", "BloemAdmin/Networking/API/HealthProbe.swift"] {
            for (path, text) in try files(under: root) where !signInFiles.contains(path) {
                checked += 1
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    // A comment may say what the code does not do.
                    let code = line.components(separatedBy: "//").first ?? line
                    for word in forbidden where code.contains(word) {
                        offenders.append("\(path):\(index + 1): \(word)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 5, "the scan should see the alert and shared sources")
        XCTAssertEqual(offenders, [])
    }

    func testTheWidgetExtensionSourcesAreScannedToo() throws {
        let widgetRoot = SourceTree.root.appendingPathComponent("BloemAdminWidgets")
        guard FileManager.default.fileExists(atPath: widgetRoot.path) else { return }
        for (path, text) in try files(under: "BloemAdminWidgets") {
            for word in forbidden {
                XCTAssertFalse(text.components(separatedBy: "\n").contains { ($0.components(separatedBy: "//").first ?? $0).contains(word) },
                               "\(path) mentions \(word)")
            }
        }
    }

    func testOnlyTheNamedWidgetFilesHandleATokenAndNeverTheAppsOwnStore() throws {
        XCTAssertEqual(signInFiles.count, 3)
        for path in signInFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: SourceTree.root.appendingPathComponent(path).path), "\(path) moved: update signInFiles")
        }
        for (path, text) in try files(under: "BloemAdmin/Shared/Widgets") {
            let code = text.components(separatedBy: "\n").map { $0.components(separatedBy: "//").first ?? $0 }.joined(separator: "\n")
            if !signInFiles.contains(path) {
                for word in ["Keychain", "accessToken", "refreshToken", "Bearer", "SecItem"] {
                    XCTAssertFalse(code.contains(word), "\(path) handles a sign-in (\(word)) but is not one of the named files")
                }
            }
            // The widget reads the mirror, never the app's own credential store or session.
            for word in ["KeychainCredentialStore", "ServerStore", "AdminSessionState", "KeychainStore"] {
                XCTAssertFalse(code.contains(word), "\(path) reaches the app's own sign-in store (\(word))")
            }
        }
    }

    func testNoPermissionRequestOutsideTheSettingsModel() throws {
        var offenders: [String] = []
        for file in try SourceTree.appSources() where file.path != "Alerts/NotificationAuthorizer.swift" {
            for (index, line) in file.lines.enumerated() where line.contains("requestAuthorization") {
                offenders.append("\(file.path):\(index + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "only NotificationAuthorizer may ask, and only the settings model calls it")
    }
}
