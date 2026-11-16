import UserNotifications
import XCTest
@testable import BloemAdmin

/// A tap on a notification and its Approve and Decline buttons.
final class PushResponseTests: XCTestCase {
    private func info(
        server: String? = "home", kind: String? = "admin.request_waiting", page: String? = "requests", item: String? = "req-9"
    ) -> PushTapInfo {
        var userInfo: [AnyHashable: Any] = [PushUserInfo.marker: "1"]
        if let server { userInfo[PushUserInfo.serverID] = server }
        if let kind { userInfo[PushUserInfo.kind] = kind }
        if let page { userInfo[PushUserInfo.page] = page }
        if let item { userInfo[PushUserInfo.itemID] = item }
        return PushTapInfo(userInfo: userInfo)
    }

    // MARK: Taps (deep links)

    func testATapOnARequestOpensThatRequest() {
        XCTAssertEqual(
            PushResponse.interpret(actionIdentifier: UNNotificationDefaultActionIdentifier, info: info()),
            .open(DeepLinkRoute(target: .server("home"), pageID: "work.requests", itemID: "req-9"))
        )
    }

    func testEachKindOpensItsPlace() {
        let places: [(kind: String, page: String?, item: String?, route: DeepLinkRoute)] = [
            ("admin.scan_failed", "libraries", "lib-4", DeepLinkRoute(target: .server("home"), pageID: "content.libraries", itemID: "lib-4")),
            ("admin.backup_failed", "backups", nil, DeepLinkRoute(target: .server("home"), pageID: "system.backups")),
            ("admin.node_offline", "nodes", nil, DeepLinkRoute(target: .server("home"), pageID: "playback.nodes")),
            ("admin.plugin_failed", "plugins", "inst-2", DeepLinkRoute(target: .server("home"), pageID: "system.plugins", itemID: "inst-2")),
            ("admin.server_down", nil, nil, DeepLinkRoute(target: .server("home"), pageID: nil)),
            ("admin.server_up", nil, nil, DeepLinkRoute(target: .server("home"), pageID: nil)),
        ]
        for place in places {
            let response = PushResponse.interpret(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                info: info(kind: place.kind, page: place.page, item: place.item)
            )
            XCTAssertEqual(response, .open(place.route), place.kind)
        }
    }

    func testAnItemOnlyTravelsWithAPage() {
        XCTAssertEqual(
            info(page: nil, item: "req-9").route,
            DeepLinkRoute(target: .server("home"), pageID: nil)
        )
    }

    func testALocalServerAlertStillOpensItsServer() {
        let local = PushTapInfo(userInfo: ["serverID": "home"])
        XCTAssertEqual(
            PushResponse.interpret(actionIdentifier: UNNotificationDefaultActionIdentifier, info: local),
            .open(DeepLinkRoute(target: .server("home"), pageID: nil))
        )
        let alert = AlertNotificationContent.serverDown(
            serverID: "home", name: "Home", since: nil, reason: nil, showsDetails: false
        )
        XCTAssertEqual(PushTapInfo(userInfo: alert.userInfo).route, alert.route)
    }

    func testANotificationThatNamesNoServerOpensNothing() {
        XCTAssertNil(info(server: nil).route)
        XCTAssertEqual(PushResponse.interpret(actionIdentifier: UNNotificationDefaultActionIdentifier, info: info(server: nil)), .ignore)
        XCTAssertEqual(PushResponse.interpret(actionIdentifier: UNNotificationDefaultActionIdentifier, info: PushTapInfo(userInfo: [:])), .ignore)
        XCTAssertEqual(PushResponse.interpret(actionIdentifier: UNNotificationDefaultActionIdentifier, info: info(server: "")), .ignore)
    }

    func testAPageOrKindThisBuildDoesNotKnowIsDropped() {
        let unknown = info(kind: "admin.disk_full", page: "dashboard", item: "x")
        XCTAssertNil(unknown.kind)
        XCTAssertNil(unknown.page)
        XCTAssertEqual(unknown.route, DeepLinkRoute(target: .server("home"), pageID: nil))
    }

    func testDismissingDoesNothing() {
        XCTAssertEqual(PushResponse.interpret(actionIdentifier: UNNotificationDismissActionIdentifier, info: info()), .ignore)
        XCTAssertEqual(PushResponse.interpret(actionIdentifier: "com.example.other", info: info()), .ignore)
    }

    // MARK: Buttons

    func testApproveAndDeclineNameTheirServerAndRequest() {
        XCTAssertEqual(
            PushResponse.interpret(actionIdentifier: PushActionID.approve, info: info()),
            .decide(serverID: "home", requestID: "req-9", approve: true)
        )
        XCTAssertEqual(
            PushResponse.interpret(actionIdentifier: PushActionID.decline, info: info()),
            .decide(serverID: "home", requestID: "req-9", approve: false)
        )
    }

    func testAButtonOnAnythingButARequestNoticeDoesNothing() {
        for kind in ["admin.scan_failed", "admin.backup_failed", "admin.node_offline", "admin.plugin_failed", nil] {
            XCTAssertEqual(PushResponse.interpret(actionIdentifier: PushActionID.approve, info: info(kind: kind)), .ignore, kind ?? "nil")
        }
    }

    func testAButtonWithoutItsRequestOrServerDoesNothing() {
        XCTAssertEqual(PushResponse.interpret(actionIdentifier: PushActionID.approve, info: info(item: nil)), .ignore)
        XCTAssertEqual(PushResponse.interpret(actionIdentifier: PushActionID.decline, info: info(server: nil)), .ignore)
    }

    func testTheButtonsNeedTheUnlockedPhoneAndNeitherIsDestructive() {
        let category = PushCategories.request()
        XCTAssertEqual(category.identifier, PushCategoryID.request)
        XCTAssertEqual(category.actions.map(\.identifier), [PushActionID.approve, PushActionID.decline])
        XCTAssertEqual(category.actions.map(\.title), ["Approve", "Decline"])
        for action in category.actions {
            XCTAssertTrue(action.options.contains(.authenticationRequired), action.identifier)
            XCTAssertFalse(action.options.contains(.destructive), action.identifier)
            XCTAssertFalse(action.options.contains(.foreground), "they run without opening the app")
        }
    }

    func testOnlyTheRequestCategoryHasButtonsAndEveryCategoryHidesItsBodyWhenPreviewsAreHidden() {
        XCTAssertEqual(PushCategories.general().actions, [])
        XCTAssertEqual(PushCategories.general().identifier, PushCategoryID.general)
        for category in PushCategories.all() {
            XCTAssertFalse(category.hiddenPreviewsBodyPlaceholder.isEmpty, category.identifier)
        }
        XCTAssertEqual(
            Set(PushCategories.all().map(\.identifier)),
            [AlertCategory.server, PushCategoryID.request, PushCategoryID.general]
        )
    }

    // MARK: Running a button

    private func runner(_ decider: FakeDecider, _ notifier: FakePushNotifier, reloads: PushCallCounter = PushCallCounter(), budget: Duration = .seconds(5)) -> PushActionRunner {
        PushActionRunner(decider: decider, notifier: notifier, afterAnswer: { reloads.bump() }, budget: budget)
    }

    func testApprovingCallsTheServerAndTakesTheNotificationAway() async {
        let decider = FakeDecider(.done)
        let notifier = FakePushNotifier()
        let reloads = PushCallCounter()
        await runner(decider, notifier, reloads: reloads).run(serverID: "home", requestID: "req-9", approve: true, notificationIdentifier: "n-1")

        XCTAssertEqual(decider.calls, [FakeDecider.Call(serverID: "home", requestID: "req-9", approve: true)])
        XCTAssertEqual(notifier.removed, ["n-1"])
        XCTAssertEqual(notifier.posted, [])
        XCTAssertEqual(reloads.count, 1, "the widgets show the new count")
    }

    func testDecliningCallsDecline() async {
        let decider = FakeDecider(.done)
        await runner(decider, FakePushNotifier()).run(serverID: "home", requestID: "req-9", approve: false, notificationIdentifier: "n-1")
        XCTAssertEqual(decider.calls.first?.approve, false)
    }

    func testARequestSomeoneElseAnsweredIsDoneToo() async {
        let notifier = FakePushNotifier()
        await runner(FakeDecider(.alreadyHandled), notifier).run(serverID: "home", requestID: "req-9", approve: true, notificationIdentifier: "n-1")
        XCTAssertEqual(notifier.removed, ["n-1"])
        XCTAssertEqual(notifier.posted, [])
    }

    func testAFailedApproveSaysCouldntApproveAndOpensTheRequest() async throws {
        let notifier = FakePushNotifier()
        await runner(FakeDecider(.failed), notifier).run(serverID: "home", requestID: "req-9", approve: true, notificationIdentifier: "n-1")

        let note = try XCTUnwrap(notifier.posted.first)
        XCTAssertEqual(note.title, "Couldn't approve, open the app")
        XCTAssertEqual(note.identifier, "n-1", "it replaces the notification it answers")
        XCTAssertEqual(notifier.removed, [])
        let tap = PushTapInfo(userInfo: note.userInfo)
        XCTAssertEqual(tap.route, DeepLinkRoute(target: .server("home"), pageID: "work.requests", itemID: "req-9"))
    }

    func testAFailedDeclineSaysCouldntDecline() async {
        let notifier = FakePushNotifier()
        await runner(FakeDecider(.failed), notifier).run(serverID: "home", requestID: "req-9", approve: false, notificationIdentifier: "n-1")
        XCTAssertEqual(notifier.posted.first?.title, "Couldn't decline, open the app")
    }

    func testAFailureNoticeNamesNoOneAndIsNotAnotherButtonSet() async throws {
        let notifier = FakePushNotifier()
        await runner(FakeDecider(.failed), notifier).run(serverID: "home", requestID: "req-9", approve: true, notificationIdentifier: "n-1")
        let note = try XCTUnwrap(notifier.posted.first)
        XCTAssertFalse(note.title.contains("Sam") || note.title.contains("Dune"))
        XCTAssertEqual(note.threadIdentifier, "home.admin.request_waiting")
    }

    func testAnAnswerThatNeverComesIsAFailureWithinTheBudget() async {
        let notifier = FakePushNotifier()
        let started = ContinuousClock.now
        await runner(FakeDecider(.done, delay: .seconds(60)), notifier, budget: .milliseconds(100))
            .run(serverID: "home", requestID: "req-9", approve: true, notificationIdentifier: "n-1")

        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
        XCTAssertEqual(notifier.posted.first?.title, "Couldn't approve, open the app")
        XCTAssertEqual(notifier.removed, [])
    }

    func testTheFailureWordsAreTheSpecs() {
        XCTAssertEqual(PushActionRunner.failureTitle(approve: true), "Couldn't approve, open the app")
        XCTAssertEqual(PushActionRunner.failureTitle(approve: false), "Couldn't decline, open the app")
    }

    // MARK: The widgets' client does the work

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var value: [String] { lock.withLock { list } }
        func add(_ call: String) { lock.withLock { list.append(call) } }
    }

    private final class ActAPI: WidgetServerAPI, @unchecked Sendable {
        let result: Result<Void, WidgetAPIError>
        let calls: Calls
        init(_ result: Result<Void, WidgetAPIError>, calls: Calls) { self.result = result; self.calls = calls }
        func sessions() async throws -> [WidgetSessionDTO] { [] }
        func requestCapabilities() async throws -> Bool { true }
        func requestCounts() async throws -> WidgetRequestCountsDTO { WidgetRequestCountsDTO(needsApproval: 0) }
        func pendingRequests(limit: Int) async throws -> [WidgetRequestDTO] { [] }
        func users() async throws -> [WidgetUserDTO] { [] }
        func libraries() async throws -> [WidgetLibraryDTO] { [] }
        func activeScans() async throws -> [WidgetScanRunDTO] { [] }
        func libraryRefreshJobs() async throws -> [WidgetRefreshJobDTO] { [] }
        func nodes() async throws -> [WidgetNodeDTO] { [] }
        func act(on requestID: String, _ action: WidgetRequestAction) async throws {
            calls.add("\(action.rawValue) \(requestID)")
            try result.get()
        }
    }

    private final class Credentials: SharedCredentialStoring, @unchecked Sendable {
        let read: SharedCredentialRead
        init(_ read: SharedCredentialRead) { self.read = read }
        func read(serverID: String) -> SharedCredentialRead { read }
        func write(_ credential: SharedCredential, serverID: String) throws {}
        func delete(serverID: String) {}
    }

    private final class NoData: WidgetDataStoring, @unchecked Sendable {
        func load() -> WidgetDataCache { WidgetDataCache() }
        func save(_ cache: WidgetDataCache) throws {}
    }

    private func decider(_ result: Result<Void, WidgetAPIError>, calls: Calls, credential: SharedCredentialRead? = nil) -> WidgetRequestDecider {
        let found = credential ?? .found(SharedCredential(accessToken: "t", refreshToken: nil, updatedAt: Date(), source: .app))
        let fetcher = WidgetFetcher(
            credentials: Credentials(found), lock: CredentialRefreshLock(fileURL: nil), dataStore: NoData(),
            api: { _, _ in ActAPI(result, calls: calls) }, refresh: { _, _ in throw WidgetAPIError(status: 401) }, now: { Date() }
        )
        return WidgetRequestDecider(fetcher: fetcher, servers: { [AdminServer.fixture("home")] })
    }

    func testTheDeciderApprovesAndDeclinesThroughTheWidgetsRoute() async {
        let calls = Calls()
        let subject = decider(.success(()), calls: calls)
        let approved = await subject.decide(serverID: "home", requestID: "req-9", approve: true)
        let declined = await subject.decide(serverID: "home", requestID: "req-8", approve: false)

        XCTAssertEqual(approved, .done)
        XCTAssertEqual(declined, .done)
        XCTAssertEqual(calls.value, ["approve req-9", "decline req-8"])
    }

    func testTheDeciderTreatsAGoneOrAnsweredRequestAsAlreadyHandled() async {
        for status in [404, 409] {
            let outcome = await decider(.failure(WidgetAPIError(status: status)), calls: Calls())
                .decide(serverID: "home", requestID: "req-9", approve: true)
            XCTAssertEqual(outcome, .alreadyHandled, "\(status)")
        }
    }

    func testTheDeciderFailsOnEverythingElse() async {
        for status in [500, 403, nil] {
            let outcome = await decider(.failure(WidgetAPIError(status: status)), calls: Calls())
                .decide(serverID: "home", requestID: "req-9", approve: true)
            XCTAssertEqual(outcome, .failed, "\(String(describing: status))")
        }
    }

    func testTheDeciderFailsWhenSignedOutOrTheServerIsNotSaved() async {
        let calls = Calls()
        let signedOut = await decider(.success(()), calls: calls, credential: .missing).decide(serverID: "home", requestID: "r", approve: true)
        let locked = await decider(.success(()), calls: calls, credential: .locked).decide(serverID: "home", requestID: "r", approve: true)
        let unknown = await decider(.success(()), calls: calls).decide(serverID: "not-saved", requestID: "r", approve: true)

        XCTAssertEqual([signedOut, locked, unknown], [.failed, .failed, .failed])
        XCTAssertEqual(calls.value, [], "an id that is not saved never falls back to another server")
    }

    func testTheDeciderFailsWithoutTheAppGroup() async {
        let subject = WidgetRequestDecider(fetcher: nil, servers: { [AdminServer.fixture("home")] })
        let outcome = await subject.decide(serverID: "home", requestID: "r", approve: true)
        XCTAssertEqual(outcome, .failed)
    }
}
