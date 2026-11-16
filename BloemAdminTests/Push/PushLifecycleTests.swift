import XCTest
@testable import BloemAdmin

/// Push follows the saved servers: told when one signs in, signs out or is removed, and the local
/// "Server is back" notice has its own switch.
@MainActor
final class PushLifecycleTests: XCTestCase {
    private final class Recorder: PushLifecycle {
        private(set) var events: [String] = []
        func serverSignedIn(_ server: AdminServer) { events.append("in \(server.id)") }
        func serverSignedOut(_ server: AdminServer) { events.append("out \(server.id)") }
    }

    private let server = AdminServer.fixture("home", name: "Silo Home")

    private func store(_ recorder: Recorder) -> ServerStore {
        let store = makeIsolatedServerStore()
        store.pushLifecycle = recorder
        return store
    }

    // MARK: ServerStore

    func testAddingAServerIsASignIn() throws {
        let recorder = Recorder()
        let store = store(recorder)
        try store.addServer(server, accessToken: "a", refreshToken: "r")
        XCTAssertEqual(recorder.events, ["in home"])
    }

    func testSigningOutAndRemovingAreSignOuts() throws {
        let recorder = Recorder()
        let store = store(recorder)
        try store.addServer(server, accessToken: "a", refreshToken: "r")

        try store.signOut("home")
        try store.removeServer("home")

        XCTAssertEqual(recorder.events, ["in home", "out home", "out home"])
    }

    func testASilentTokenRefreshIsNotASignIn() throws {
        let recorder = Recorder()
        let store = store(recorder)
        try store.addServer(server, accessToken: "a", refreshToken: "r")
        try store.updateToken("a2", refreshToken: "r2", forServerID: "home")
        try store.updateCredentials(ServerCredentials.rotated, forServerID: "home")
        XCTAssertEqual(recorder.events, ["in home"])
    }

    func testAnInteractiveSignInIsOneForTheServerSaved() throws {
        let recorder = Recorder()
        let store = store(recorder)
        try store.addServer(server, accessToken: "a", refreshToken: "r")
        store.noteInteractiveSignIn(serverID: "home")
        store.noteInteractiveSignIn(serverID: "not-saved")
        XCTAssertEqual(recorder.events, ["in home", "in home"])
    }

    func testAServerThatWasNeverSavedIsNotSignedOut() throws {
        let recorder = Recorder()
        let store = store(recorder)
        try store.removeServer("never-saved")
        try store.signOut("never-saved")
        XCTAssertEqual(recorder.events, [])
    }

    func testAStoreWithNoLifecycleWorksAsBefore() throws {
        let store = makeIsolatedServerStore()
        try store.addServer(server, accessToken: "a", refreshToken: "r")
        try store.signOut("home")
        try store.removeServer("home")
        XCTAssertEqual(store.servers, [])
    }

    func testTheRuntimeIsTheLifecycleTheAppUses() {
        let lifecycle: any PushLifecycle = PushRuntime.shared
        XCTAssertNotNil(lifecycle)
    }

    // MARK: The "Server is back" notice

    private func runner(
        defaults: UserDefaults, clock: AlertTestClock, probe: FakeProbe, notifier: FakeNotifier, backAllowed: Bool
    ) -> (AlertRunner, AlertPreferences) {
        let preferences = AlertPreferences(defaults: defaults)
        preferences.isEnabled = true
        preferences.setServer("a", enabled: true)
        let runner = AlertRunner(
            preferences: preferences, loadServers: { [.fixture("a", name: "Silo Home")] }, probe: probe, notifier: notifier,
            authorizer: FakeAuthorizer(.allowed), snapshots: InMemorySnapshotStore(), reloader: FakeReloader(),
            planner: BackgroundCheckPlanner(scheduler: FakeBackgroundScheduler(), now: clock.reader), now: clock.reader,
            backNoticeAllowed: { _ in backAllowed }
        )
        return (runner, preferences)
    }

    private func goDownThenUp(backAllowed: Bool) async -> FakeNotifier {
        let (defaults, suite) = AlertTestDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = AlertTestClock()
        let probe = FakeProbe()
        let notifier = FakeNotifier()
        let (runner, _) = runner(defaults: defaults, clock: clock, probe: probe, notifier: notifier, backAllowed: backAllowed)
        let url = AdminServer.fixture("a").baseURL
        probe.set(.down(.timedOut), for: url)
        _ = await runner.run()
        clock.advance(15 * 60)
        _ = await runner.run()
        probe.set(.up, for: url)
        clock.advance(15 * 60)
        _ = await runner.run()
        return notifier
    }

    func testAServerBackIsReportedWhileItsSwitchIsOn() async {
        let notifier = await goDownThenUp(backAllowed: true)
        XCTAssertEqual(notifier.posted.map(\.title), ["Can't reach Silo Home", "Silo Home is answering again"])
    }

    func testAServerBackIsNotReportedWhenItsSwitchIsOffButTheDownNoticeStillGoes() async {
        let notifier = await goDownThenUp(backAllowed: false)
        XCTAssertEqual(notifier.posted.map(\.title), ["Can't reach Silo Home"])
        XCTAssertTrue(notifier.removed.contains("bloem.admin.alert.down.a"), "a switched-off alert already showing still goes away when the server is back")
    }

    func testTheServerBackSwitchIsPerServer() {
        let (defaults, suite) = AlertTestDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PushPreferences(defaults: defaults)
        preferences.setKind(.serverUp, enabled: false, serverID: "a")
        XCTAssertFalse(preferences.isEnabled(.serverUp, serverID: "a"))
        XCTAssertTrue(preferences.isEnabled(.serverUp, serverID: "b"))
    }

    func testTheLockScreenSettingReachesTheExtensionsFile() {
        let store = FakePushSettings()
        PushSettingsMirror.sync(showsDetails: true, store: store)
        XCTAssertTrue(store.load().showDetailsOnLockScreen)
    }
}
