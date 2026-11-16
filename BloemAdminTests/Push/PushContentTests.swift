import XCTest
@testable import BloemAdmin

/// What a push carries, and what the server's text is cleaned into before it is shown.
final class PushContentTests: XCTestCase {
    // MARK: The wire id

    func testAWellFormedDeliveryIdIsRead() {
        let wire = PushWire(raw: "dev1.0b8c4c1e-5f0e-5d2a-9a3e-aaaaaaaaaaaa")
        XCTAssertEqual(wire?.deviceID, "dev1")
        XCTAssertEqual(wire?.deliveryID, "0b8c4c1e-5f0e-5d2a-9a3e-aaaaaaaaaaaa")
        XCTAssertEqual(wire?.contentID, "dev1.0b8c4c1e-5f0e-5d2a-9a3e-aaaaaaaaaaaa")
    }

    func testThePayloadKeyIsTheRelaysAndOnlyAStringCounts() {
        XCTAssertEqual(PushWire.deliveryKey, "bloem_delivery_id")
        XCTAssertEqual(PushWire(userInfo: ["bloem_delivery_id": "dev1.abc"])?.deviceID, "dev1")
        XCTAssertNil(PushWire(userInfo: ["bloem_delivery_id": 42]))
        XCTAssertNil(PushWire(userInfo: ["aps": ["alert": "hi"]]))
        XCTAssertNil(PushWire(userInfo: [:]))
    }

    func testAnythingElseIsRefusedNotGuessedAt() {
        let refused = [
            "", "dev1", "dev1.", ".abc", "dev1.abc.def", "dev 1.abc", "dev1.ab/c", "dev1.ab?c", "de.v1.abc",
            "dev1.abc\n", "dév.abc", "dev1.abc%2F",
        ]
        for raw in refused { XCTAssertNil(PushWire(raw: raw), raw.debugDescription) }
        XCTAssertNil(PushWire(raw: "dev1." + String(repeating: "a", count: PushWire.maxLength)))
        XCTAssertNotNil(PushWire(raw: "dev1." + String(repeating: "a", count: PushWire.maxLength - 5)))
    }

    // MARK: Decoding what the server answers

    func testTheServersAnswerDecodes() {
        let content = PushSamples.content()
        XCTAssertEqual(content.kind, "admin.request_waiting")
        XCTAssertEqual(content.title, "Sam requested Dune")
        XCTAssertEqual(content.body, "3 waiting")
        XCTAssertEqual(content.lockScreen, "New request waiting")
        XCTAssertEqual(content.page, "requests")
        XCTAssertEqual(content.itemID, "req-9")
        XCTAssertEqual(content.actions, ["approve", "decline"])
    }

    func testOptionalFieldsMayBeMissing() throws {
        let content = try JSONDecoder().decode(PushContent.self, from: Data(#"{"kind":"admin.backup_failed","title":"Backup failed on Home"}"#.utf8))
        XCTAssertEqual(content.body, "")
        XCTAssertEqual(content.actions, [])
        XCTAssertNil(content.page)
        XCTAssertEqual(content.sanitized()?.lockScreen, "A backup failed", "a missing lock-screen text falls back to the kind's own")
    }

    func testAnAnswerWithoutAKindOrTitleDoesNotDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(PushContent.self, from: Data(#"{"title":"x"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(PushContent.self, from: Data(#"{"kind":"admin.scan_failed"}"#.utf8)))
    }

    // MARK: Cleaning it

    func testARequestNoticeKeepsItsButtonsAndItsItem() throws {
        let display = try XCTUnwrap(PushSamples.content().sanitized())
        XCTAssertEqual(display.kind, .requestWaiting)
        XCTAssertEqual(display.page, .requests)
        XCTAssertEqual(display.itemID, "req-9")
        XCTAssertEqual(display.actions, [.approve, .decline])
    }

    func testAButtonNeedsTheRequestItActsOn() throws {
        let noItem = PushContent(kind: "admin.request_waiting", title: "t", page: "requests", actions: ["approve", "decline"])
        XCTAssertEqual(noItem.sanitized()?.actions, [])
        let noPage = PushContent(kind: "admin.request_waiting", title: "t", itemID: "r1", actions: ["approve", "decline"])
        XCTAssertEqual(noPage.sanitized()?.actions, [], "an item is only meaningful on a page the app has")
        XCTAssertNil(noPage.sanitized()?.itemID)
    }

    func testOnlyARequestNoticeEverGetsButtons() throws {
        let scan = PushContent(kind: "admin.scan_failed", title: "Scan failed: Movies", page: "libraries", itemID: "lib-4", actions: ["approve"])
        XCTAssertEqual(scan.sanitized()?.actions, [])
        XCTAssertEqual(scan.sanitized()?.itemID, "lib-4")
    }

    func testOnlyApproveAndDeclineExistAsButtonsAndNeverTwice() {
        let content = PushContent(
            kind: "admin.request_waiting", title: "t", page: "requests", itemID: "r1",
            actions: ["delete", "approve", "approve", "decline", "suspend"]
        )
        XCTAssertEqual(content.sanitized()?.actions, [.approve, .decline])
    }

    func testAPageTheAppDoesNotHaveIsDropped() {
        let content = PushContent(kind: "admin.node_offline", title: "Edge is offline", page: "dashboard", itemID: "n1")
        let display = content.sanitized()
        XCTAssertNil(display?.page)
        XCTAssertNil(display?.itemID)
    }

    func testEveryPageTheServerNamesHasAnAppPage() {
        XCTAssertEqual(
            PushLinkPage.allCases.map(\.pageID).sorted(),
            ["content.libraries", "playback.nodes", "system.backups", "system.plugins", "work.requests"]
        )
        for page in PushLinkPage.allCases {
            XCTAssertNotNil(PushContent(kind: "admin.scan_failed", title: "t", page: page.rawValue, itemID: "1").sanitized()?.page)
        }
    }

    func testAKindThisBuildDoesNotKnowIsNotShown() {
        XCTAssertNil(PushContent(kind: "admin.disk_full", title: "t").sanitized())
        XCTAssertNil(PushContent(kind: "hq.ticket", title: "t").sanitized())
    }

    func testATitleThatIsEmptyAfterCleaningIsNotShown() {
        XCTAssertNil(PushContent(kind: "admin.scan_failed", title: " \n\t ").sanitized())
        XCTAssertNil(PushContent(kind: "admin.scan_failed", title: "\u{0007}\u{0000}").sanitized())
    }

    func testTextIsOneShortLine() throws {
        let long = String(repeating: "a", count: 300)
        let content = PushContent(kind: "admin.scan_failed", title: "Scan\nfailed:\t  Movies\u{0007}", body: long, lockScreen: "A library\nscan failed")
        let display = try XCTUnwrap(content.sanitized())
        XCTAssertEqual(display.title, "Scan failed: Movies")
        XCTAssertEqual(display.lockScreen, "A library scan failed")
        XCTAssertEqual(display.body.count, PushDisplay.maxText)
        XCTAssertTrue(display.body.hasSuffix("…"))
    }

    func testAnItemIdThatIsTooLongIsDropped() {
        let item = String(repeating: "x", count: PushDisplay.maxItemID + 1)
        XCTAssertNil(PushContent(kind: "admin.scan_failed", title: "t", page: "libraries", itemID: item).sanitized()?.itemID)
        let fits = String(repeating: "x", count: PushDisplay.maxItemID)
        XCTAssertEqual(PushContent(kind: "admin.scan_failed", title: "t", page: "libraries", itemID: fits).sanitized()?.itemID, fits)
    }

    // MARK: The kinds

    func testTheKindIdsAreTheStableKeysOfTheSpec() {
        XCTAssertEqual(PushKind.allCases.map(\.rawValue), [
            "admin.server_down", "admin.server_up", "admin.request_waiting", "admin.scan_failed",
            "admin.backup_failed", "admin.node_offline", "admin.plugin_failed",
        ])
    }

    func testTwoKindsAreLocalAndTheRestComeFromTheServer() {
        XCTAssertEqual(PushKind.allCases.filter(\.isLocal), [.serverDown, .serverUp])
        XCTAssertEqual(PushKind.remote, [.requestWaiting, .scanFailed, .backupFailed, .nodeOffline, .pluginFailed])
    }

    func testTheLockScreenTextIsTheSpecsWithNoTrailingPeriod() {
        let expected: [PushKind: String] = [
            .serverDown: "A server can't be reached", .serverUp: "A server is back", .requestWaiting: "New request waiting",
            .scanFailed: "A library scan failed", .backupFailed: "A backup failed", .nodeOffline: "A node is offline",
            .pluginFailed: "A plugin needs attention",
        ]
        for kind in PushKind.allCases {
            XCTAssertEqual(kind.lockScreenText, expected[kind], kind.rawValue)
            XCTAssertFalse(kind.lockScreenText.hasSuffix("."))
        }
    }

    func testDownAndUpShareAThreadAndOtherKindsDoNot() {
        XCTAssertEqual(PushKind.serverDown.threadIdentifier(serverID: "s1"), PushKind.serverUp.threadIdentifier(serverID: "s1"))
        let threads = Set(PushKind.allCases.map { $0.threadIdentifier(serverID: "s1") })
        XCTAssertEqual(threads.count, PushKind.allCases.count - 1)
        XCTAssertNotEqual(PushKind.scanFailed.threadIdentifier(serverID: "s1"), PushKind.scanFailed.threadIdentifier(serverID: "s2"))
    }

    func testTheAppSaysSiloAndNeverBloemInItsOwnWords() {
        for kind in PushKind.allCases {
            XCTAssertFalse(kind.settingsLabel.contains("Bloem"), kind.settingsLabel)
            XCTAssertFalse(kind.lockScreenText.contains("Bloem"), kind.lockScreenText)
        }
        XCTAssertFalse(PushNotificationComposer.genericTitle.contains("Bloem"))
        XCTAssertFalse(PushNotificationComposer.genericBody.contains("Bloem"))
        for status in [PushStatus.unknown, .plainSilo, .notAvailableYet, .needsAdminAccount, .signedOut, .needsPermission, .waitingForToken, .registered, .failed] {
            XCTAssertFalse(PushSettingsModel.text(for: status).contains("Bloem"), "\(status)")
        }
    }
}
