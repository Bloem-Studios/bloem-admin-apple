import XCTest
@testable import BloemAdmin

/// Preferences and the background check's scheduling.
final class AlertPlanningTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private let id = BackgroundCheckPlanner.identifier

    override func setUp() {
        (defaults, suite) = AlertTestDefaults.make()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Preferences

    func testEverythingIsOffUntilTurnedOn() {
        let preferences = AlertPreferences(defaults: defaults)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertFalse(preferences.showsDetails)
        XCTAssertTrue(preferences.enabledServerIDs.isEmpty)
        XCTAssertFalse(preferences.isServerEnabled("a"))
        XCTAssertTrue(preferences.checkableServerIDs(saved: ["a"]).isEmpty)
    }

    func testPerServerSwitchesAreKeptAndOnlyCountWhileTheMasterIsOn() {
        let preferences = AlertPreferences(defaults: defaults)
        preferences.setServer("a", enabled: true)
        preferences.setServer("b", enabled: true)
        preferences.setServer("b", enabled: false)
        XCTAssertEqual(preferences.enabledServerIDs, ["a"])
        XCTAssertTrue(preferences.checkableServerIDs(saved: ["a", "b"]).isEmpty, "master is off")
        preferences.isEnabled = true
        XCTAssertEqual(preferences.checkableServerIDs(saved: ["a", "b"]), ["a"])
        XCTAssertTrue(preferences.checkableServerIDs(saved: ["b"]).isEmpty, "a is not saved")
        XCTAssertEqual(AlertPreferences(defaults: defaults).enabledServerIDs, ["a"], "persisted")
    }

    func testPruneForgetsServersThatAreGone() {
        let preferences = AlertPreferences(defaults: defaults)
        preferences.setServer("a", enabled: true)
        preferences.setServer("b", enabled: true)
        preferences.setState(ServerAlertState(consecutiveFailures: 1), for: "a")
        preferences.setState(ServerAlertState(consecutiveFailures: 1), for: "b")
        preferences.prune(keeping: ["a"])
        XCTAssertEqual(preferences.enabledServerIDs, ["a"])
        XCTAssertEqual(preferences.state(for: "a").consecutiveFailures, 1)
        XCTAssertEqual(preferences.state(for: "b"), ServerAlertState())
    }

    func testStateRoundTripsAndClears() {
        let preferences = AlertPreferences(defaults: defaults)
        let state = ServerAlertState(
            consecutiveFailures: 2, isReportedDown: true,
            firstFailureAt: Date(timeIntervalSince1970: 100), lastCheckAt: Date(timeIntervalSince1970: 200),
            lastFailure: .serverError(502)
        )
        preferences.setState(state, for: "a")
        XCTAssertEqual(AlertPreferences(defaults: defaults).state(for: "a"), state)
        preferences.clearStates()
        XCTAssertEqual(preferences.state(for: "a"), ServerAlertState())
    }

    // MARK: Scheduling

    private func planner(_ scheduler: FakeBackgroundScheduler, _ clock: AlertTestClock) -> BackgroundCheckPlanner {
        BackgroundCheckPlanner(scheduler: scheduler, now: clock.reader)
    }

    func testNothingIsScheduledWhileAlertsAreOff() {
        let scheduler = FakeBackgroundScheduler()
        let preferences = AlertPreferences(defaults: defaults)
        preferences.setServer("a", enabled: true)
        planner(scheduler, AlertTestClock()).reschedule(preferences: preferences, savedServerIDs: ["a"])
        XCTAssertEqual(scheduler.calls, [.cancel(id)])
    }

    func testNothingIsScheduledWhenNoSavedServerHasAlertsOn() {
        let scheduler = FakeBackgroundScheduler()
        let preferences = AlertPreferences(defaults: defaults)
        preferences.isEnabled = true
        planner(scheduler, AlertTestClock()).reschedule(preferences: preferences, savedServerIDs: ["a"])
        XCTAssertEqual(scheduler.calls, [.cancel(id)])
    }

    func testOneCheckIsRequestedFifteenMinutesAhead() {
        let scheduler = FakeBackgroundScheduler()
        let clock = AlertTestClock()
        let preferences = AlertPreferences(defaults: defaults)
        preferences.isEnabled = true
        preferences.setServer("a", enabled: true)
        planner(scheduler, clock).reschedule(preferences: preferences, savedServerIDs: ["a", "b"])
        XCTAssertEqual(scheduler.calls, [.submit(id, clock.now.addingTimeInterval(15 * 60))])
    }

    func testRemovingTheLastServerWithAlertsStopsTheBackgroundWork() {
        let scheduler = FakeBackgroundScheduler()
        let preferences = AlertPreferences(defaults: defaults)
        preferences.isEnabled = true
        preferences.setServer("a", enabled: true)
        let planner = planner(scheduler, AlertTestClock())
        planner.reschedule(preferences: preferences, savedServerIDs: ["a", "b"])
        planner.reschedule(preferences: preferences, savedServerIDs: ["b"])
        XCTAssertEqual(scheduler.last, .cancel(id))
    }

    func testTheIdentifierIsTheOneDeclaredInProjectYml() throws {
        let yml = try String(contentsOf: SourceTree.root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("BGTaskSchedulerPermittedIdentifiers"))
        XCTAssertTrue(yml.contains("- \(BackgroundCheckPlanner.identifier)"))
        XCTAssertTrue(yml.contains("UIBackgroundModes"))
        XCTAssertEqual(BackgroundCheckPlanner.identifier, "com.bloemstudios.admin.health-check")
    }
}
