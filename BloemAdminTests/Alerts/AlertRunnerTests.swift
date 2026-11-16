import XCTest
@testable import BloemAdmin

/// One check of every saved server: what it asks, what it tells the person, and what it leaves behind.
final class AlertRunnerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        (defaults, suite) = AlertTestDefaults.make()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private final class ServerList: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [AdminServer]
        init(_ list: [AdminServer]) { self.list = list }
        var value: [AdminServer] { get { lock.withLock { list } } set { lock.withLock { list = newValue } } }
    }

    private struct Rig {
        let runner: AlertRunner
        let preferences: AlertPreferences
        let probe: FakeProbe
        let notifier: FakeNotifier
        let snapshots: InMemorySnapshotStore
        let reloader: FakeReloader
        let scheduler: FakeBackgroundScheduler
        let clock: AlertTestClock
        let servers: ServerList
    }

    private func rig(
        servers: [AdminServer], permission: NotificationPermission = .allowed,
        snapshot: AdminSnapshot? = nil, defaults: UserDefaults
    ) -> Rig {
        let clock = AlertTestClock()
        let preferences = AlertPreferences(defaults: defaults)
        let probe = FakeProbe()
        let notifier = FakeNotifier()
        let snapshots = InMemorySnapshotStore(snapshot)
        let reloader = FakeReloader()
        let scheduler = FakeBackgroundScheduler()
        let list = ServerList(servers)
        let runner = AlertRunner(
            preferences: preferences,
            loadServers: { list.value },
            probe: probe,
            notifier: notifier,
            authorizer: FakeAuthorizer(permission),
            snapshots: snapshots,
            reloader: reloader,
            planner: BackgroundCheckPlanner(scheduler: scheduler, now: clock.reader),
            now: clock.reader
        )
        return Rig(
            runner: runner, preferences: preferences, probe: probe, notifier: notifier, snapshots: snapshots,
            reloader: reloader, scheduler: scheduler, clock: clock, servers: list
        )
    }

    private func turnOn(_ rig: Rig, servers ids: [String]) {
        rig.preferences.isEnabled = true
        ids.forEach { rig.preferences.setServer($0, enabled: true) }
    }

    private let quarterHour: TimeInterval = 15 * 60

    // MARK: Off

    func testDoesNothingWhileAlertsAreOff() async {
        let rig = rig(servers: [.fixture("a")], defaults: defaults)
        let summary = await rig.runner.run()
        XCTAssertTrue(rig.probe.asked.isEmpty)
        XCTAssertTrue(rig.notifier.posted.isEmpty)
        XCTAssertEqual(rig.snapshots.saves, 0)
        XCTAssertEqual(summary.checkedServerIDs, [])
        XCTAssertEqual(rig.scheduler.last, .cancel(BackgroundCheckPlanner.identifier))
    }

    // MARK: Down and back

    func testReportsAServerDownOnTheSecondFailureOnly() async {
        let server = AdminServer.fixture("a", name: "Silo Home")
        let rig = rig(servers: [server], defaults: defaults)
        turnOn(rig, servers: ["a"])
        rig.probe.set(.down(.timedOut), for: server.baseURL)

        _ = await rig.runner.run()
        XCTAssertTrue(rig.notifier.posted.isEmpty, "one failure is not enough")

        rig.clock.advance(quarterHour)
        _ = await rig.runner.run()
        XCTAssertEqual(rig.notifier.posted.map(\.title), ["Can't reach Silo Home"])
        XCTAssertEqual(rig.notifier.posted.first?.body, "Open Bloem Admin to check the server")
        XCTAssertEqual(rig.notifier.posted.first?.serverID, "a")

        rig.clock.advance(quarterHour)
        _ = await rig.runner.run()
        XCTAssertEqual(rig.notifier.posted.count, 1, "reported once")
    }

    func testReportsItBackAndClearsTheEarlierNotice() async {
        let server = AdminServer.fixture("a", name: "Silo Home")
        let rig = rig(servers: [server], defaults: defaults)
        turnOn(rig, servers: ["a"])
        rig.probe.set(.down(.cannotConnect), for: server.baseURL)
        _ = await rig.runner.run()
        rig.clock.advance(quarterHour)
        _ = await rig.runner.run()
        XCTAssertTrue(rig.notifier.removed.contains("bloem.admin.alert.back.a"), "a new down notice replaces a back notice")

        rig.probe.set(.up, for: server.baseURL)
        rig.clock.advance(quarterHour)
        _ = await rig.runner.run()
        XCTAssertEqual(rig.notifier.posted.map(\.title), ["Can't reach Silo Home", "Silo Home is answering again"])
        XCTAssertTrue(rig.notifier.removed.contains("bloem.admin.alert.down.a"))
    }

    func testAServerThatFlapsIsNeverReported() async {
        let server = AdminServer.fixture("a")
        let rig = rig(servers: [server], defaults: defaults)
        turnOn(rig, servers: ["a"])
        for index in 0..<8 {
            rig.probe.set(index.isMultiple(of: 2) ? .down(.timedOut) : .up, for: server.baseURL)
            _ = await rig.runner.run()
            rig.clock.advance(quarterHour)
        }
        XCTAssertTrue(rig.notifier.posted.isEmpty)
    }

    func testDetailsAppearOnlyWhenTheDeviceSwitchIsOn() async {
        let server = AdminServer.fixture("a", name: "Silo Home")
        let rig = rig(servers: [server], defaults: defaults)
        turnOn(rig, servers: ["a"])
        rig.preferences.showsDetails = true
        rig.probe.set(.down(.serverError(503)), for: server.baseURL)
        _ = await rig.runner.run()
        rig.clock.advance(quarterHour)
        _ = await rig.runner.run()
        let body = rig.notifier.posted.first?.body ?? ""
        XCTAssertTrue(body.hasPrefix("No answer since "), body)
        XCTAssertTrue(body.hasSuffix("(server error 503)"), body)
    }

    func testAPhoneWithNoNetworkNeverCountsAgainstTheServer() async {
        let server = AdminServer.fixture("a")
        let rig = rig(servers: [server], defaults: defaults)
        turnOn(rig, servers: ["a"])
        rig.probe.set(.inconclusive, for: server.baseURL)
        for _ in 0..<4 {
            _ = await rig.runner.run()
            rig.clock.advance(quarterHour)
        }
        XCTAssertTrue(rig.notifier.posted.isEmpty)
        XCTAssertEqual(rig.preferences.state(for: "a"), ServerAlertState())
    }

    // MARK: Permission gating

    func testWithoutPermissionNothingIsPostedAndTheCountsAreNotAdvanced() async {
        let server = AdminServer.fixture("a")
        let rig = rig(servers: [server], permission: .denied, defaults: defaults)
        turnOn(rig, servers: ["a"])
        rig.probe.set(.down(.timedOut), for: server.baseURL)
        for _ in 0..<3 {
            _ = await rig.runner.run()
            rig.clock.advance(quarterHour)
        }
        XCTAssertTrue(rig.notifier.posted.isEmpty)
        XCTAssertEqual(rig.preferences.state(for: "a"), ServerAlertState())
        XCTAssertEqual(rig.snapshots.load()?.servers.first?.reachable, false, "widgets still learn the status")
    }

    func testNotDeterminedIsNotPermission() async {
        let server = AdminServer.fixture("a")
        let authorizer = FakeAuthorizer(.notDetermined)
        let clock = AlertTestClock()
        let preferences = AlertPreferences(defaults: defaults)
        preferences.isEnabled = true
        preferences.setServer("a", enabled: true)
        let notifier = FakeNotifier()
        let probe = FakeProbe()
        probe.set(.down(.timedOut), for: server.baseURL)
        let runner = AlertRunner(
            preferences: preferences, loadServers: { [server] }, probe: probe, notifier: notifier,
            authorizer: authorizer, snapshots: InMemorySnapshotStore(), reloader: FakeReloader(),
            planner: BackgroundCheckPlanner(scheduler: FakeBackgroundScheduler(), now: clock.reader),
            now: clock.reader
        )
        _ = await runner.run()
        clock.advance(quarterHour)
        _ = await runner.run()
        XCTAssertTrue(notifier.posted.isEmpty)
        XCTAssertEqual(authorizer.requests, 0, "a background check never asks for permission")
    }

    // MARK: Which servers

    func testEveryServerIsCheckedButOnlyThoseWithAlertsOnAreReported() async {
        let a = AdminServer.fixture("a"), b = AdminServer.fixture("b")
        let rig = rig(servers: [a, b], defaults: defaults)
        turnOn(rig, servers: ["a"])
        rig.probe.set(.down(.timedOut), for: a.baseURL)
        rig.probe.set(.down(.timedOut), for: b.baseURL)
        _ = await rig.runner.run()
        rig.clock.advance(quarterHour)
        let summary = await rig.runner.run()

        XCTAssertEqual(Set(rig.probe.asked.map(\.absoluteString)), [a.baseURL.absoluteString, b.baseURL.absoluteString])
        XCTAssertEqual(summary.checkedServerIDs, ["a", "b"])
        XCTAssertEqual(rig.notifier.posted.map(\.serverID), ["a"])
        let snapshot = rig.snapshots.load()
        XCTAssertEqual(snapshot?.servers.map(\.reachable), [false, false])
    }

    func testAnInsecureAddressIsNeverAsked() async {
        let insecure = AdminServer(id: "a", baseURL: URL(string: "http://old.example.test")!, displayName: "Old")
        let rig = rig(servers: [insecure], defaults: defaults)
        turnOn(rig, servers: ["a"])
        let summary = await rig.runner.run()
        XCTAssertTrue(rig.probe.asked.isEmpty)
        XCTAssertEqual(summary.checkedServerIDs, [])
        XCTAssertNil(rig.snapshots.load()?.servers.first?.origin)
    }

    func testARemovedServerIsForgottenAndTheBackgroundWorkStops() async {
        let a = AdminServer.fixture("a"), b = AdminServer.fixture("b")
        let rig = rig(servers: [a, b], defaults: defaults)
        turnOn(rig, servers: ["a", "b"])
        rig.probe.set(.down(.timedOut), for: a.baseURL)
        _ = await rig.runner.run()
        XCTAssertEqual(rig.preferences.state(for: "a").consecutiveFailures, 1)

        rig.servers.value = [b]
        let probesBefore = rig.probe.asked.count
        _ = await rig.runner.run()
        XCTAssertEqual(rig.probe.asked.count - probesBefore, 1, "only b is asked")
        XCTAssertEqual(rig.preferences.enabledServerIDs, ["b"])
        XCTAssertEqual(rig.preferences.state(for: "a"), ServerAlertState())
        XCTAssertEqual(rig.snapshots.load()?.servers.map(\.id), ["b"])
        XCTAssertEqual(rig.scheduler.last?.isSubmit, true)

        rig.servers.value = []
        _ = await rig.runner.run()
        XCTAssertEqual(rig.scheduler.last, .cancel(BackgroundCheckPlanner.identifier))
        XCTAssertTrue(rig.preferences.enabledServerIDs.isEmpty)
    }

    // MARK: What it leaves behind

    func testReschedulesTheNextCheck() async {
        let rig = rig(servers: [.fixture("a")], defaults: defaults)
        turnOn(rig, servers: ["a"])
        _ = await rig.runner.run()
        XCTAssertEqual(
            rig.scheduler.last,
            .submit(BackgroundCheckPlanner.identifier, rig.clock.now.addingTimeInterval(quarterHour))
        )
    }

    func testWritesTheSnapshotKeepingCountsAndReloadsWidgets() async {
        let server = AdminServer.fixture("a", name: "Home")
        let clock = AlertTestClock()
        let earlier = AdminSnapshot.make(
            previous: nil,
            servers: [SnapshotServerInfo(id: "a", name: "Home", origin: server.baseURL)],
            reachability: [:], counts: ["a": .set(SnapshotCounts(streams: 3, requests: 4))],
            now: clock.now.addingTimeInterval(-60)
        )
        let rig = rig(servers: [server], snapshot: earlier, defaults: defaults)
        turnOn(rig, servers: ["a"])
        _ = await rig.runner.run()
        let saved = rig.snapshots.load()?.servers.first
        XCTAssertEqual(saved?.reachable, true)
        XCTAssertEqual(saved?.activeStreams, 3)
        XCTAssertEqual(saved?.requestsWaiting, 4)
        XCTAssertEqual(saved?.origin, server.baseURL)
        XCTAssertEqual(rig.reloader.count, 1)
    }
}

private extension FakeBackgroundScheduler.Call {
    var isSubmit: Bool {
        if case .submit = self { return true }
        return false
    }
}
