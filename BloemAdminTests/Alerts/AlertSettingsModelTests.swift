import XCTest
@testable import BloemAdmin

/// The App settings section's logic: when permission is asked for, and what each switch does.
@MainActor
final class AlertSettingsModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        (defaults, suite) = AlertTestDefaults.make()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private struct Rig {
        let model: AlertSettingsModel
        let preferences: AlertPreferences
        let authorizer: FakeAuthorizer
        let scheduler: FakeBackgroundScheduler
        let notifier: FakeNotifier
        let openedSettings: Counter
    }

    @MainActor
    final class Counter {
        var value = 0
    }

    private func rig(
        _ permission: NotificationPermission, answer: Bool = true,
        servers: [AdminServer] = [.fixture("a"), .fixture("b")]
    ) -> Rig {
        let preferences = AlertPreferences(defaults: defaults)
        let authorizer = FakeAuthorizer(permission, answer: answer)
        let scheduler = FakeBackgroundScheduler()
        let notifier = FakeNotifier()
        let opened = Counter()
        let model = AlertSettingsModel(
            preferences: preferences,
            authorizer: authorizer,
            notifier: notifier,
            planner: BackgroundCheckPlanner(scheduler: scheduler, now: AlertTestClock().reader),
            servers: servers,
            openSystemSettings: { opened.value += 1 }
        )
        return Rig(model: model, preferences: preferences, authorizer: authorizer, scheduler: scheduler,
                   notifier: notifier, openedSettings: opened)
    }

    // MARK: Never at launch

    func testCreatingAndLoadingNeverAsksForPermission() async {
        let rig = rig(.notDetermined)
        XCTAssertEqual(rig.authorizer.requests, 0)
        await rig.model.load()
        XCTAssertEqual(rig.authorizer.requests, 0)
        XCTAssertFalse(rig.model.isOn)
        XCTAssertFalse(rig.model.showsDetails)
        XCTAssertEqual(rig.model.permission, .notDetermined)
    }

    // MARK: Turning alerts on

    func testTurningOnAsksOnceAndKeepsTheAnswer() async {
        let rig = rig(.notDetermined)
        await rig.model.setEnabled(true)
        XCTAssertEqual(rig.authorizer.requests, 1)
        XCTAssertTrue(rig.model.isOn)
        XCTAssertTrue(rig.preferences.isEnabled)
        XCTAssertEqual(rig.model.permission, .allowed)

        await rig.model.setEnabled(false)
        await rig.model.setEnabled(true)
        XCTAssertEqual(rig.authorizer.requests, 1, "already answered")
    }

    func testRefusingThePromptLeavesAlertsOffAndSaysWhy() async {
        let rig = rig(.notDetermined, answer: false)
        await rig.model.setEnabled(true)
        XCTAssertFalse(rig.model.isOn)
        XCTAssertFalse(rig.preferences.isEnabled)
        XCTAssertEqual(rig.model.permission, .denied)
        XCTAssertEqual(rig.scheduler.last, .cancel(BackgroundCheckPlanner.identifier))
    }

    func testPermissionAlreadyDeniedIsNotAskedForAgain() async {
        let rig = rig(.denied)
        await rig.model.load()
        XCTAssertEqual(rig.model.permission, .denied)
        await rig.model.setEnabled(true)
        XCTAssertEqual(rig.authorizer.requests, 0)
        XCTAssertFalse(rig.model.isOn)
        rig.model.openSystemSettings()
        XCTAssertEqual(rig.openedSettings.value, 1)
    }

    func testPermissionAlreadyGrantedTurnsOnWithoutAPrompt() async {
        let rig = rig(.allowed)
        await rig.model.setEnabled(true)
        XCTAssertEqual(rig.authorizer.requests, 0)
        XCTAssertTrue(rig.model.isOn)
    }

    func testAlertsShowOffWhenPermissionWasTakenBackInSettings() async {
        let rig = rig(.denied)
        rig.preferences.isEnabled = true
        await rig.model.load()
        XCTAssertFalse(rig.model.isOn)
        XCTAssertEqual(rig.model.permission, .denied)
    }

    // MARK: Turning alerts off

    func testTurningOffStopsBackgroundWorkAndClearsWhatWasShown() async {
        let rig = rig(.allowed)
        await rig.model.setEnabled(true)
        rig.model.setServer("a", enabled: true)
        XCTAssertEqual(rig.scheduler.last?.isSubmit, true)
        rig.preferences.setState(ServerAlertState(consecutiveFailures: 1), for: "a")

        await rig.model.setEnabled(false)
        XCTAssertFalse(rig.model.isOn)
        XCTAssertEqual(rig.scheduler.last, .cancel(BackgroundCheckPlanner.identifier))
        XCTAssertEqual(rig.preferences.state(for: "a"), ServerAlertState())
        XCTAssertEqual(
            Set(rig.notifier.removed),
            Set(AlertNotificationContent.identifiers(forServer: "a") + AlertNotificationContent.identifiers(forServer: "b"))
        )
        XCTAssertEqual(rig.model.enabledServerIDs, ["a"], "per-server choices are kept")
    }

    // MARK: Servers and details

    func testServerSwitchesStartOffAndScheduleTheCheck() async {
        let rig = rig(.allowed)
        XCTAssertFalse(rig.model.isServerOn("a"))
        await rig.model.setEnabled(true)
        XCTAssertEqual(rig.scheduler.last, .cancel(BackgroundCheckPlanner.identifier), "no server is on yet")
        rig.model.setServer("a", enabled: true)
        XCTAssertTrue(rig.model.isServerOn("a"))
        XCTAssertFalse(rig.model.isServerOn("b"))
        XCTAssertEqual(rig.scheduler.last?.isSubmit, true)
        rig.model.setServer("a", enabled: false)
        XCTAssertEqual(rig.scheduler.last, .cancel(BackgroundCheckPlanner.identifier))
    }

    func testDetailsSwitchIsPerDeviceAndOffByDefault() {
        let rig = rig(.allowed)
        XCTAssertFalse(rig.model.showsDetails)
        rig.model.setShowsDetails(true)
        XCTAssertTrue(rig.model.showsDetails)
        XCTAssertTrue(AlertPreferences(defaults: defaults).showsDetails)
    }
}

private extension FakeBackgroundScheduler.Call {
    var isSubmit: Bool {
        if case .submit = self { return true }
        return false
    }
}
