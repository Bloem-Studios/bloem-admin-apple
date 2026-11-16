import UserNotifications
import XCTest
@testable import BloemAdmin

/// What the phone shows for a push, and above all what it does not: with "Show details on the lock screen"
/// off, a notification carries only the server's lock-screen text.
final class PushNotificationComposerTests: XCTestCase {
    private let registration = PushRegistration.fixture(name: "Silo Home")

    private func display(_ json: String = PushSamples.requestJSON) throws -> PushDisplay {
        try XCTUnwrap(PushSamples.content(json).sanitized())
    }

    /// Every string the plan hands to the system, so a test can look for a name anywhere in it.
    private func everything(in plan: PushNotificationPlan) -> String {
        ([plan.title, plan.subtitle, plan.body, plan.threadIdentifier, plan.categoryIdentifier]
            + plan.userInfo.keys + plan.userInfo.values).joined(separator: "\n")
    }

    // MARK: Details off

    func testWithDetailsOffOnlyTheLockScreenTextShows() throws {
        let plan = PushNotificationComposer.compose(registration: registration, display: try display(), showsDetails: false)
        XCTAssertEqual(plan.title, "New request waiting")
        XCTAssertEqual(plan.subtitle, "")
        XCTAssertEqual(plan.body, "")
    }

    func testWithDetailsOffNoNameTitleCountOrServerNameIsAnywhereInThePlan() throws {
        let plan = PushNotificationComposer.compose(registration: registration, display: try display(), showsDetails: false)
        let text = everything(in: plan)
        for secret in ["Sam", "Dune", "3 waiting", "Silo Home", "requested"] {
            XCTAssertFalse(text.contains(secret), "\(secret) is in: \(text)")
        }
    }

    func testEveryKindKeepsItsDetailsOutWhenOff() throws {
        let kinds: [(String, String, String)] = [
            ("admin.scan_failed", "Scan failed: Private Movies", "libraries"),
            ("admin.backup_failed", "Backup failed on Alex's Home", "backups"),
            ("admin.node_offline", "Basement GPU is offline", "nodes"),
            ("admin.plugin_failed", "Secret Plugin needs attention", "plugins"),
        ]
        for (kind, title, page) in kinds {
            let content = PushContent(kind: kind, title: title, body: "Since 12:00 UTC", lockScreen: "", page: page, itemID: "item-1")
            let plan = PushNotificationComposer.compose(registration: registration, display: content.sanitized(), showsDetails: false)
            let text = everything(in: plan)
            for secret in [title, "Since 12:00", "Silo Home", "Private", "Alex", "Basement", "Secret"] {
                XCTAssertFalse(text.contains(secret), "\(kind): \(secret) is in: \(text)")
            }
            XCTAssertEqual(plan.title, PushKind(rawValue: kind)?.lockScreenText, kind)
        }
    }

    func testTheGenericTextNamesNoServerWithDetailsOff() {
        let plan = PushNotificationComposer.compose(registration: registration, display: nil, showsDetails: false)
        XCTAssertEqual(plan.subtitle, "")
        XCTAssertFalse(everything(in: plan).contains("Silo Home"))
    }

    // MARK: Details on

    func testWithDetailsOnTheRealTitleBodyAndServerShow() throws {
        let plan = PushNotificationComposer.compose(registration: registration, display: try display(), showsDetails: true)
        XCTAssertEqual(plan.title, "Sam requested Dune")
        XCTAssertEqual(plan.subtitle, "Silo Home")
        XCTAssertEqual(plan.body, "3 waiting")
    }

    // MARK: The fetch failed

    func testWithoutTheServersTextTheGenericTextShows() {
        let plan = PushNotificationComposer.compose(registration: registration, display: nil, showsDetails: false)
        XCTAssertEqual(plan.title, "New notification")
        XCTAssertEqual(plan.body, "Open the app to see it")
        XCTAssertEqual(plan.categoryIdentifier, PushCategoryID.general)
        XCTAssertEqual(plan.userInfo[PushUserInfo.serverID], "home", "a tap still opens the server")
    }

    func testWithDetailsOnTheGenericTextMayNameTheServer() {
        let plan = PushNotificationComposer.compose(registration: registration, display: nil, showsDetails: true)
        XCTAssertEqual(plan.title, "New notification")
        XCTAssertEqual(plan.subtitle, "Silo Home")
    }

    func testAPushForADeviceThisPhoneDoesNotHaveIsGenericAndOpensNothingInParticular() {
        let plan = PushNotificationComposer.compose(registration: nil, display: nil, showsDetails: true)
        XCTAssertEqual(plan.title, "New notification")
        XCTAssertEqual(plan.subtitle, "")
        XCTAssertNil(plan.userInfo[PushUserInfo.serverID])
        XCTAssertEqual(plan.threadIdentifier, PushNotificationComposer.unknownThread)
    }

    // MARK: Grouping, buttons and where a tap goes

    func testNotificationsGroupByServerAndKind() throws {
        let request = PushNotificationComposer.compose(registration: registration, display: try display(), showsDetails: false)
        let scan = PushNotificationComposer.compose(registration: registration, display: try display(PushSamples.scanJSON), showsDetails: false)
        let other = PushNotificationComposer.compose(
            registration: PushRegistration.fixture(server: "lab"), display: try display(), showsDetails: false
        )
        XCTAssertEqual(request.threadIdentifier, "home.admin.request_waiting")
        XCTAssertEqual(scan.threadIdentifier, "home.admin.scan_failed")
        XCTAssertEqual(other.threadIdentifier, "lab.admin.request_waiting")
    }

    func testARequestNoticeGetsApproveAndDeclineAndNothingElseDoes() throws {
        let request = PushNotificationComposer.compose(registration: registration, display: try display(), showsDetails: false)
        let scan = PushNotificationComposer.compose(registration: registration, display: try display(PushSamples.scanJSON), showsDetails: false)
        XCTAssertEqual(request.categoryIdentifier, PushCategoryID.request)
        XCTAssertEqual(scan.categoryIdentifier, PushCategoryID.general)
    }

    func testHalfAPairOfButtonsIsNoButtons() {
        let content = PushContent(kind: "admin.request_waiting", title: "t", page: "requests", itemID: "r1", actions: ["approve"])
        let plan = PushNotificationComposer.compose(registration: registration, display: content.sanitized(), showsDetails: false)
        XCTAssertEqual(plan.categoryIdentifier, PushCategoryID.general)
    }

    func testATapCarriesIdentifiersOnly() throws {
        let plan = PushNotificationComposer.compose(registration: registration, display: try display(), showsDetails: false)
        XCTAssertEqual(plan.userInfo, [
            PushUserInfo.marker: "1", PushUserInfo.serverID: "home", PushUserInfo.kind: "admin.request_waiting",
            PushUserInfo.page: "requests", PushUserInfo.itemID: "req-9",
        ])
    }

    // MARK: Applying it

    func testApplyingAPlanReplacesTheRelaysTextAndKeepsItsKeys() throws {
        let content = UNMutableNotificationContent()
        content.title = "Bloem"
        content.body = "New notification available"
        content.userInfo = ["aps": ["badge": 4], "bloem_delivery_id": "dev1.abc-1"]
        let plan = PushNotificationComposer.compose(registration: registration, display: try display(), showsDetails: true)

        plan.apply(to: content)

        XCTAssertEqual(content.title, "Sam requested Dune")
        XCTAssertEqual(content.subtitle, "Silo Home")
        XCTAssertEqual(content.body, "3 waiting")
        XCTAssertEqual(content.threadIdentifier, "home.admin.request_waiting")
        XCTAssertEqual(content.categoryIdentifier, PushCategoryID.request)
        XCTAssertEqual(content.userInfo["bloem_delivery_id"] as? String, "dev1.abc-1")
        XCTAssertNotNil(content.userInfo["aps"], "the relay's count for the app icon is left alone")
        XCTAssertEqual(content.userInfo[PushUserInfo.serverID] as? String, "home")
        XCTAssertEqual(content.badge, nil, "the badge is the relay's, not the extension's")
    }
}
