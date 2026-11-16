import XCTest
@testable import BloemAdmin

/// Every word push shows the person is in the string catalog, in sentence case with no trailing period.
final class PushStringCatalogTests: XCTestCase {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Push
        .deletingLastPathComponent()  // BloemAdminTests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("BloemAdmin/Localizable.xcstrings")

    private func catalogKeys() throws -> Set<String> {
        let data = try Data(contentsOf: Self.catalogURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(try XCTUnwrap(root["strings"] as? [String: Any]).keys)
    }

    private var shown: [String] {
        PushKind.allCases.flatMap { [$0.lockScreenText, $0.settingsLabel] }
            + [PushNotificationComposer.genericTitle, PushNotificationComposer.genericBody]
            + [PushStatus.unknown, .plainSilo, .notAvailableYet, .needsAdminAccount, .signedOut, .needsPermission, .waitingForToken, .registered, .failed]
                .map(PushSettingsModel.text(for:))
            + [PushActionRunner.failureTitle(approve: true), PushActionRunner.failureTitle(approve: false)]
            + PushCategories.request().actions.map(\.title)
            + [PushCategories.request().hiddenPreviewsBodyPlaceholder, PushCategories.general().hiddenPreviewsBodyPlaceholder]
    }

    func testEveryWordPushShowsIsInTheCatalog() throws {
        let keys = try catalogKeys()
        for text in shown { XCTAssertTrue(keys.contains(text), "missing catalog key: \(text)") }
        for text in [
            "Allow notifications", "Notifications", "No servers saved", "Open iOS Settings",
            "Open iOS Settings, tap Notifications, then turn on Allow Notifications",
            "Notifications are off for this app in iOS Settings",
            "A server can notify you when something is broken or waiting on you. Switch each kind on or off per server",
        ] {
            XCTAssertTrue(keys.contains(text), "missing catalog key: \(text)")
        }
    }

    func testTheWordsAreSentenceCaseWithNoTrailingPeriod() {
        for text in shown {
            XCTAssertFalse(text.hasSuffix("."), text)
            XCTAssertEqual(text.first.map(String.init)?.uppercased(), text.first.map(String.init), "starts with a capital: \(text)")
        }
    }
}
