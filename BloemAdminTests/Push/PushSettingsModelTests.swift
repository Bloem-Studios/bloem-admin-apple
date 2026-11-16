import XCTest
@testable import BloemAdmin

/// Settings → Notifications: a switch per kind per server, what each server's section says, and the
/// permission help.
@MainActor
final class PushSettingsModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var alertDefaults: UserDefaults!
    private var suites: [String] = []

    override func setUp() {
        let (a, aSuite) = AlertTestDefaults.make()
        let (b, bSuite) = AlertTestDefaults.make()
        defaults = a
        alertDefaults = b
        suites = [aSuite, bSuite]
    }

    override func tearDown() {
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
    }

    private let home = AdminServer.fixture("home", name: "Silo Home")
    private let plain = AdminServer.fixture("plain", name: "Plain Silo")

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var calls_: [String] = []
        var calls: [String] { lock.withLock { calls_ } }
        func add(_ call: String) { lock.withLock { calls_.append(call) } }
    }

    private struct Rig {
        let model: PushSettingsModel
        let preferences: PushPreferences
        let alerts: AlertSettingsModel
        let alertPreferences: AlertPreferences
        let authorizer: FakeAuthorizer
        let sent: Sent
        let refreshes: PushCallCounter
        let openedSettings: PushCallCounter
    }

    private func rig(permission: NotificationPermission = .allowed, answer: Bool = true, servers: [AdminServer]? = nil) -> Rig {
        let preferences = PushPreferences(defaults: defaults)
        let alertPreferences = AlertPreferences(defaults: alertDefaults)
        let authorizer = FakeAuthorizer(permission, answer: answer)
        let list = servers ?? [home, plain]
        let alerts = AlertSettingsModel(
            preferences: alertPreferences, authorizer: authorizer, notifier: FakeNotifier(),
            planner: BackgroundCheckPlanner(scheduler: FakeBackgroundScheduler(), now: AlertTestClock().reader),
            servers: list, openSystemSettings: {}
        )
        let sent = Sent()
        let refreshes = PushCallCounter()
        let opened = PushCallCounter()
        let model = PushSettingsModel(
            servers: list, preferences: preferences, alerts: alerts, authorizer: authorizer,
            // What `PushRegistrar.setKind` does: keep the choice here first, then tell the server.
            sendKind: { kind, enabled, server in
                preferences.setKind(kind, enabled: enabled, serverID: server.id)
                sent.add("\(server.id) \(kind.rawValue) \(enabled)")
            },
            refresh: { refreshes.bump() },
            openSystemSettings: { opened.bump() }
        )
        return Rig(
            model: model, preferences: preferences, alerts: alerts, alertPreferences: alertPreferences,
            authorizer: authorizer, sent: sent, refreshes: refreshes, openedSettings: opened
        )
    }

    // MARK: What each server's section lists

    func testAServerThatCanPushListsEveryKind() {
        let rig = rig()
        rig.preferences.setStatus(.registered, serverID: "home")
        XCTAssertEqual(rig.model.kinds(for: home), PushKind.allCases)
        XCTAssertEqual(rig.model.kinds(for: home).count, 7)
    }

    func testAPlainSiloServerListsOnlyTheTwoLocalKindsAndSaysWhy() {
        let rig = rig()
        rig.preferences.setStatus(.plainSilo, serverID: "plain")
        XCTAssertEqual(rig.model.kinds(for: plain), [.serverDown, .serverUp])
        XCTAssertEqual(rig.model.status(plain), .plainSilo)
        XCTAssertEqual(
            PushSettingsModel.text(for: rig.model.status(plain)),
            "Push isn't available on this server. Only the server-down checks apply"
        )
    }

    func testAServerWithoutPushYetListsTheLocalKindsAndSaysYet() {
        let rig = rig()
        rig.preferences.setStatus(.notAvailableYet, serverID: "home")
        XCTAssertEqual(rig.model.kinds(for: home), [.serverDown, .serverUp])
        XCTAssertEqual(
            PushSettingsModel.text(for: .notAvailableYet),
            "Push isn't available on this server yet. Only the server-down checks apply"
        )
    }

    func testASignedOutServerListsTheLocalKindsOnly() {
        let rig = rig()
        rig.preferences.setStatus(.signedOut, serverID: "home")
        XCTAssertEqual(rig.model.kinds(for: home), [.serverDown, .serverUp])
    }

    func testAServerNotAskedYetListsEveryKind() {
        XCTAssertEqual(rig().model.kinds(for: home), PushKind.allCases)
    }

    func testEveryStatusHasWordsWithNoTrailingPeriod() {
        for status in [PushStatus.unknown, .plainSilo, .notAvailableYet, .needsAdminAccount, .signedOut, .needsPermission, .waitingForToken, .registered, .failed] {
            let text = PushSettingsModel.text(for: status)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.hasSuffix("."), text)
        }
    }

    func testAnInsecureServerIsNotListed() {
        let insecure = AdminServer(id: "old", baseURL: URL(string: "http://old.example.test")!, displayName: "Old")
        let rig = rig(servers: [home, insecure])
        XCTAssertEqual(rig.model.servers.map(\.id), ["home"])
    }

    // MARK: Switches

    func testEveryKindIsOnUntilSwitchedOff() {
        let rig = rig()
        for kind in PushKind.allCases where kind != .serverDown {
            XCTAssertTrue(rig.model.isOn(kind, server: home), kind.rawValue)
        }
    }

    func testASwitchIsKeptHereAndSentToTheServer() async {
        let rig = rig()
        await rig.model.set(.backupFailed, on: false, server: home)

        XCTAssertFalse(rig.model.isOn(.backupFailed, server: home))
        XCTAssertFalse(rig.preferences.isEnabled(.backupFailed, serverID: "home"))
        XCTAssertEqual(rig.sent.calls, ["home admin.backup_failed false"])

        await rig.model.set(.backupFailed, on: true, server: home)
        XCTAssertTrue(rig.model.isOn(.backupFailed, server: home))
        XCTAssertEqual(rig.sent.calls.last, "home admin.backup_failed true")
    }

    func testASwitchBelongsToOneServer() async {
        let rig = rig()
        await rig.model.set(.scanFailed, on: false, server: plain)
        XCTAssertTrue(rig.model.isOn(.scanFailed, server: home))
    }

    func testServerIsBackIsItsOwnLocalSwitch() async {
        let rig = rig()
        await rig.model.set(.serverUp, on: false, server: home)
        XCTAssertFalse(rig.model.isOn(.serverUp, server: home))
        XCTAssertFalse(PushPreferences(defaults: defaults).isEnabled(.serverUp, serverID: "home"))
        XCTAssertEqual(rig.sent.calls, ["home admin.server_up false"], "the model hands every non-watch kind on; the registrar keeps a local kind off the wire")
    }

    func testServerCantBeReachedIsTheServersToWatchSwitch() async {
        let rig = rig()
        XCTAssertFalse(rig.model.isOn(.serverDown, server: home))

        await rig.model.set(.serverDown, on: true, server: home)

        XCTAssertTrue(rig.alertPreferences.isEnabled, "turning it on turns Server alerts on")
        XCTAssertTrue(rig.alertPreferences.isServerEnabled("home"))
        XCTAssertTrue(rig.model.isOn(.serverDown, server: home))
        XCTAssertEqual(rig.sent.calls, [], "a local kind never leaves the phone")

        await rig.model.set(.serverDown, on: false, server: home)
        XCTAssertFalse(rig.alertPreferences.isServerEnabled("home"))
        XCTAssertFalse(rig.model.isOn(.serverDown, server: home))
    }

    func testServerCantBeReachedStaysOffWhenIosRefusesNotifications() async {
        let rig = rig(permission: .notDetermined, answer: false)
        await rig.model.set(.serverDown, on: true, server: home)
        XCTAssertFalse(rig.model.isOn(.serverDown, server: home))
        XCTAssertFalse(rig.alertPreferences.isServerEnabled("home"))
    }

    // MARK: Permission

    func testOpeningTheScreenNeverAsksForPermission() async {
        let rig = rig(permission: .notDetermined)
        rig.preferences.setStatus(.needsPermission, serverID: "home")
        await rig.model.load()
        XCTAssertEqual(rig.authorizer.requests, 0)
        XCTAssertEqual(rig.refreshes.count, 1, "it reads every server again")
        XCTAssertTrue(rig.model.offersPermissionButton)
        XCTAssertFalse(rig.model.showsPermissionHelp)
    }

    func testTheButtonAsksOnceAndRegistersWhenAllowed() async {
        let rig = rig(permission: .notDetermined)
        rig.preferences.setStatus(.needsPermission, serverID: "home")
        await rig.model.load()
        let before = rig.refreshes.count

        await rig.model.allowNotifications()

        XCTAssertEqual(rig.authorizer.requests, 1)
        XCTAssertTrue(rig.preferences.permissionAsked)
        XCTAssertEqual(rig.refreshes.count, before + 1)
        XCTAssertFalse(rig.model.offersPermissionButton)
    }

    func testWhenIosHasRefusedSettingsSaysHowToAllowIt() async {
        let rig = rig(permission: .denied)
        rig.preferences.setStatus(.needsPermission, serverID: "home")
        await rig.model.load()

        XCTAssertTrue(rig.model.showsPermissionHelp)
        XCTAssertFalse(rig.model.offersPermissionButton, "a refusal is not asked about again")
        rig.model.openSystemSettings()
        XCTAssertEqual(rig.openedSettings.count, 1)
        XCTAssertEqual(rig.authorizer.requests, 0)
    }

    func testThereIsNoPermissionNoiseWhenNoServerWaitsForIt() async {
        let rig = rig(permission: .denied)
        rig.preferences.setStatus(.plainSilo, serverID: "home")
        rig.preferences.setStatus(.plainSilo, serverID: "plain")
        await rig.model.load()
        XCTAssertFalse(rig.model.showsPermissionHelp, "a plain Silo server needs no permission, so no complaint")
        XCTAssertFalse(rig.model.offersPermissionButton)
    }

    func testNoServersIsEmptyNotAnError() {
        let rig = rig(servers: [])
        XCTAssertEqual(rig.model.servers, [])
        XCTAssertFalse(rig.model.showsPermissionHelp)
    }
}
