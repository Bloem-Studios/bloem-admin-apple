import XCTest
@testable import BloemAdmin

/// What a notification says. Generic text is the default; details are a per-device choice.
final class AlertContentTests: XCTestCase {
    private let since = Date(timeIntervalSince1970: 1_800_000_000)
    private func time(_ date: Date) -> String { "14:05" }

    func testLockScreenTextIsGenericByDefault() {
        let content = AlertNotificationContent.serverDown(
            serverID: "s1", name: "Silo Home", since: since, reason: .timedOut,
            showsDetails: false, formatTime: time
        )
        XCTAssertEqual(content.title, "Can't reach Silo Home")
        XCTAssertEqual(content.body, "Open Bloem Admin to check the server")
        XCTAssertEqual(content.kind, .serverDown)
        XCTAssertEqual(content.serverID, "s1")
        XCTAssertTrue(content.playsSound)
    }

    func testDetailsAddWhenItStoppedAndWhy() {
        let content = AlertNotificationContent.serverDown(
            serverID: "s1", name: "Silo Home", since: since, reason: .serverError(503),
            showsDetails: true, formatTime: time
        )
        XCTAssertEqual(content.title, "Can't reach Silo Home")
        XCTAssertEqual(content.body, "No answer since 14:05 (server error 503)")
    }

    func testDetailsWithoutAKnownTimeOrReasonFallBackToTheGenericBody() {
        let content = AlertNotificationContent.serverDown(
            serverID: "s1", name: "Silo Home", since: nil, reason: nil, showsDetails: true, formatTime: time
        )
        XCTAssertEqual(content.body, "Open Bloem Admin to check the server")
    }

    func testBackIsQuietAndGenericByDefault() {
        let content = AlertNotificationContent.serverBack(
            serverID: "s1", name: "Silo Home", at: since, showsDetails: false, formatTime: time
        )
        XCTAssertEqual(content.title, "Silo Home is answering again")
        XCTAssertEqual(content.body, "Open Bloem Admin to see it")
        XCTAssertFalse(content.playsSound)
        XCTAssertEqual(content.kind, .serverBack)

        let detailed = AlertNotificationContent.serverBack(
            serverID: "s1", name: "Silo Home", at: since, showsDetails: true, formatTime: time
        )
        XCTAssertEqual(detailed.body, "Answering again since 14:05")
    }

    func testTextNeverCarriesAnAddressOrAnAccount() {
        // The content is built from a server's name, a time and a failure kind. It has no input that
        // could hold an address, a person's name, an email or a title, with details on or off.
        for details in [false, true] {
            let down = AlertNotificationContent.serverDown(
                serverID: "s1", name: "Silo Home", since: since, reason: .cannotConnect,
                showsDetails: details, formatTime: time
            )
            for text in [down.title, down.body] {
                XCTAssertFalse(text.contains("http"), text)
                XCTAssertFalse(text.contains("@"), text)
                XCTAssertFalse(text.contains(".example"), text)
            }
        }
    }

    func testIdentifiersAreOnePerServerAndKind() {
        let down = AlertNotificationContent.serverDown(
            serverID: "s1", name: "A", since: since, reason: nil, showsDetails: false, formatTime: time
        )
        let back = AlertNotificationContent.serverBack(
            serverID: "s1", name: "A", at: since, showsDetails: false, formatTime: time
        )
        XCTAssertEqual(down.identifier, "bloem.admin.alert.down.s1")
        XCTAssertEqual(back.identifier, "bloem.admin.alert.back.s1")
        XCTAssertEqual(
            AlertNotificationContent.identifiers(forServer: "s1"),
            ["bloem.admin.alert.down.s1", "bloem.admin.alert.back.s1"]
        )
    }

    func testTheOpenLinkNamesTheServerOnly() {
        let content = AlertNotificationContent.serverDown(
            serverID: "s1", name: "A", since: since, reason: nil, showsDetails: false, formatTime: time
        )
        XCTAssertEqual(content.route, DeepLinkRoute(target: .server("s1"), pageID: nil))
        XCTAssertEqual(content.userInfo, ["serverID": "s1"])
    }
}
