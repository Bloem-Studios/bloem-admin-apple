import XCTest
@testable import BloemAdmin

/// What an organization page does with the organization live socket (docs/design.md): it subscribes
/// while it is visible, reads again when its channel changes, keeps exactly what it did before when the server has no
/// socket (or does not serve the channel), and does nothing in the background. The last test is the before-and-after
/// count of timed requests a minute on the Now playing page.
@MainActor
final class OrganizationLiveFollowTests: XCTestCase {
    typealias F = OrganizationFixtures

    private let clock = TestLiveClock()
    private let streams = "\(F.base)/streams"
    /// Not 60, which the watchdog also sleeps on, so the fallback minute can be told from it.
    private static let minute: TimeInterval = 77
    private static let live = "organization_live_v1"

    private func connection(_ steps: [ScriptedEndpoint.Step]) -> (LiveConnection, ScriptedEndpoint) {
        var timings = LiveTimings()
        timings.fallbackInterval = Self.minute
        let script = ScriptedEndpoint(steps)
        let made = LiveConnection(endpoint: script.endpoint, timings: timings, clock: clock, jitter: { 1 })
        made.setForeground(true)
        return (made, script)
    }

    private func server(_ http: MockHTTPHarness, features: [String]) async throws -> OrganizationSession {
        http.state.stubBloemServer(featureTokens: features)
        http.state.stub(path: streams, data: F.data(F.streams(F.stream())))
        return try await openedOrganizationSession(http)
    }

    private func reads(_ http: MockHTTPHarness) -> Int { http.state.requests(path: streams).count }

    /// The server says hello, and (once the app has subscribed) accepts it and sends its snapshot.
    private func goLive(_ socket: FakeLiveSocket) async {
        await socket.goLive(available: ["org.streams", "org.people", "org.activity"])
    }

    private final class Counter {
        var value = 0
    }

    // MARK: Whether the server has the socket

    func testOnlyAServerThatAdvertisesTheFeatureHasTheSocket() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await server(http, features: [Self.live, "organization_support_v1"])
        let offered = await session.offersLive()
        XCTAssertTrue(offered)

        http.state.stubBloemServer(featureTokens: ["organization_support_v1"])
        let without = await session.offersLive()
        XCTAssertFalse(without, "an older Bloem server")

        http.state.stubPlainSilo()
        let plain = await session.offersLive()
        XCTAssertFalse(plain)

        http.state.stub(path: "/api/bloem/v2/capabilities", data: Data(), status: 503)
        let unknown = await session.offersLive()
        XCTAssertFalse(unknown, "any doubt is no: the page keeps what it did")
    }

    func testTheSocketIsAtTheContractsRoutes() throws {
        let client = APIClient(baseURL: URL(string: "https://bloem.example/base/")!, accessToken: "pass")
        XCTAssertEqual(client.organizationLiveSocketURL?.absoluteString, "wss://bloem.example/base/api/bloem/v2/organization/live/ws")
        XCTAssertNil(APIClient(baseURL: URL(string: "http://bloem.example")!, accessToken: "pass").organizationLiveSocketURL, "never over plain HTTP")
    }

    func testTheTicketIsMintedWithThePassAndNoBody() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let ticket = String(repeating: "x", count: 43)
        http.state.stub(
            path: "/api/bloem/v2/admin/organization/live/ticket",
            data: F.data(#"{"ticket":"\#(ticket)","expires_at":"2026-11-16T12:00:30Z","protocol":"bloem-live.v1","channels":["org.streams","org.people"],"max_connection_seconds":3600}"#)
        )
        let session = try await openedOrganizationSession(http)

        let minted = try await session.read { try await $0.createOrganizationLiveTicket() }

        XCTAssertEqual(minted, OrganizationLiveTicket(ticket: ticket, channels: ["org.streams", "org.people"], maxConnectionSeconds: 3600))
        let sent = http.state.requests(path: "/api/bloem/v2/admin/organization/live/ticket")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.httpMethod, "POST")
        XCTAssertEqual(sent.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(F.pass)")
        XCTAssertNil(sent.first?.httpBody, "a body is a 400")
    }

    // MARK: With the socket

    func testAVisiblePageSubscribesToItsChannelReadsWhenItOpensAndWhenItChanges() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await server(http, features: [Self.live])
        let socket = FakeLiveSocket()
        let (live, script) = connection([.socket(socket)])
        let model = OrganizationStreamsViewModel()

        let page = Task { @MainActor in await model.watch(session: session, connection: live) }
        let opened = await waitUntil { self.reads(http) == 1 }
        XCTAssertTrue(opened, "the read on open")
        XCTAssertEqual(live.subscriberCount, 1)
        await goLive(socket)
        XCTAssertEqual(LiveFrames.parse(socket.sent.last ?? "")?.channels, ["org.streams"], "the page asks for its own channel only")
        let caughtUp = await waitUntil { self.reads(http) == 2 }
        XCTAssertTrue(caughtUp, "the connection's snapshot is one catch-up read")

        await clock.advance(2)
        socket.push(LiveFrames.event("org.streams"))
        let changed = await waitUntil { self.reads(http) == 3 }
        XCTAssertTrue(changed, "a change on the page's channel reads the list again")
        XCTAssertEqual(model.streams.count, 1)

        // A change on another page's channel is not this page's business.
        await clock.advance(2)
        let before = reads(http)
        socket.push(LiveFrames.event("org.people"))
        await TestLiveClock.settle()
        XCTAssertEqual(reads(http), before)

        XCTAssertEqual(script.attempts, 1)
        page.cancel()
        await page.value
    }

    func testNothingIsReadOnATimerWhileConnected() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await server(http, features: [Self.live])
        let socket = FakeLiveSocket()
        let (live, _) = connection([.socket(socket)])
        let model = OrganizationStreamsViewModel()
        let page = Task { @MainActor in await model.watch(session: session, connection: live) }
        _ = await waitUntil { self.reads(http) == 1 }
        await goLive(socket)
        _ = await waitUntil { self.reads(http) == 2 }
        await TestLiveClock.settle()
        let settled = reads(http)

        for _ in 0..<30 { await clock.advance(60) }

        XCTAssertEqual(reads(http), settled, "thirty minutes connected with nothing changing: not one request")
        XCTAssertEqual(clock.pendingCount, 2, "only the socket's own ping and watchdog timers run")
        XCTAssertFalse(clock.sleeps.contains(10))
        page.cancel()
        await page.value
    }

    func testLeavingThePageLetsGoOfTheSocket() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await server(http, features: [Self.live])
        let socket = FakeLiveSocket()
        let (live, _) = connection([.socket(socket)])
        let model = OrganizationStreamsViewModel()
        let page = Task { @MainActor in await model.watch(session: session, connection: live) }
        _ = await waitUntil { self.reads(http) == 1 }
        await goLive(socket)

        page.cancel()
        await page.value
        XCTAssertEqual(live.subscriberCount, 0)
        await clock.advance(11)

        XCTAssertTrue(socket.isClosed, "the socket closes ten seconds after the last page leaves")
    }

    // MARK: Keeping what the page did

    func testAServerWithoutTheSocketKeepsTheTenSecondPollAndOpensNoConnection() async throws {
        XCTAssertEqual(OrganizationStreamsViewModel.pollInterval, .seconds(10), "the pace the page has always had")
        for features in [[String](), ["organization_support_v1"]] {
            let http = MockHTTPHarness()
            defer { http.invalidate() }
            let session = try await server(http, features: features)
            let (live, script) = connection([.socket(FakeLiveSocket())])
            let model = OrganizationStreamsViewModel()

            // The same loop at a pace a test can wait for.
            let page = Task { @MainActor in await model.watch(session: session, connection: live, interval: .milliseconds(20)) }
            let polled = await waitUntil(5) { self.reads(http) >= 3 }
            page.cancel()
            await page.value

            XCTAssertTrue(polled, "the page asks again while it is open")
            XCTAssertEqual(script.attempts, 0, "no socket is opened for a server that has none")
            XCTAssertEqual(live.subscriberCount, 0)
        }
    }

    func testAPlainSiloOrAnUnreachableCapabilityRouteKeepsThePollToo() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await server(http, features: [])
        http.state.stubPlainSilo()
        let (live, script) = connection([.socket(FakeLiveSocket())])
        let model = OrganizationStreamsViewModel()

        let page = Task { @MainActor in await model.watch(session: session, connection: live, interval: .milliseconds(20)) }
        let polled = await waitUntil(5) { self.reads(http) >= 3 }
        page.cancel()
        await page.value

        XCTAssertTrue(polled)
        XCTAssertEqual(script.attempts, 0)
    }

    func testAServerThatDoesNotServeTheStreamsChannelKeepsTheTenSecondPace() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await server(http, features: [Self.live])
        let socket = FakeLiveSocket()
        let (live, _) = connection([.socket(socket)])
        let model = OrganizationStreamsViewModel()
        let page = Task { @MainActor in await model.watch(session: session, connection: live) }
        _ = await waitUntil { self.reads(http) == 1 }
        // The ticket does not list org.streams: the server cannot list live sessions.
        socket.push(LiveFrames.hello(["org.people", "org.activity"]))
        await TestLiveClock.settle()
        XCTAssertEqual(live.unavailableChannels, [.orgStreams])
        let base = reads(http)

        for tick in 1...3 {
            await clock.advance(10)
            let read = await waitUntil { self.reads(http) == base + tick }
            XCTAssertTrue(read, "a read every ten seconds, as before (tick \(tick))")
        }
        XCTAssertFalse(clock.sleeps.contains(Self.minute), "the minute fallback is not what runs")
        page.cancel()
        await page.value
    }

    func testPeopleAndActivityReadOnOpenOnlyWhenTheSocketIsNotThere() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await server(http, features: [])
        let (live, script) = connection([.socket(FakeLiveSocket())])

        // People already read themselves on open (the filter task), so there is nothing to do without the socket.
        let people = Counter()
        let activity = Counter()
        let a = Task { @MainActor in
            await OrganizationLive.follow(
                session: session, channel: .orgPeople, connection: live, whenNotOffered: .readOnOpenOnly, readOnOpen: false,
                legacy: {}, refresh: { people.value += 1 }
            )
        }
        let b = Task { @MainActor in
            await OrganizationLive.follow(
                session: session, channel: .orgActivity, connection: live, whenNotOffered: .readOnOpenOnly,
                legacy: { activity.value += 1 }, refresh: { activity.value += 1 }
            )
        }
        await a.value
        await b.value
        for _ in 0..<60 { await clock.advance(60) }

        XCTAssertEqual(people.value, 0)
        XCTAssertEqual(activity.value, 1, "Activity reads on open, as before")
        XCTAssertEqual(script.attempts, 0)
    }

    func testPeopleAndActivityFollowTheirChannelsWithTheSocket() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await server(http, features: [Self.live])
        let socket = FakeLiveSocket()
        let (live, _) = connection([.socket(socket)])
        let people = Counter()
        let activity = Counter()
        let a = Task { @MainActor in
            await OrganizationLive.follow(
                session: session, channel: .orgPeople, connection: live, whenNotOffered: .readOnOpenOnly, readOnOpen: false,
                legacy: {}, refresh: { people.value += 1 }
            )
        }
        let b = Task { @MainActor in
            await OrganizationLive.follow(
                session: session, channel: .orgActivity, connection: live, whenNotOffered: .readOnOpenOnly,
                legacy: { activity.value += 1 }, refresh: { activity.value += 1 }
            )
        }
        _ = await waitUntil { activity.value == 1 && live.subscriberCount == 2 }
        await goLive(socket)
        let caughtUp = await waitUntil { people.value == 1 && activity.value == 2 }
        XCTAssertTrue(caughtUp, "People has no read of its own on open, so only the socket's catch-up reads it")

        await clock.advance(2)
        socket.push(LiveFrames.event("org.people"))
        let moved = await waitUntil { people.value == 2 }
        XCTAssertTrue(moved)
        XCTAssertEqual(activity.value, 2, "a change in People is not Activity's")
        a.cancel(); b.cancel()
        await a.value; await b.value
    }

    // MARK: Nothing in the background

    func testWithTheAppInTheBackgroundNoSocketIsOpenedAndNothingIsRead() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await server(http, features: [Self.live])
        let (live, script) = connection([.socket(FakeLiveSocket())])
        live.setForeground(false)
        let model = OrganizationStreamsViewModel()

        let page = Task { @MainActor in await model.watch(session: session, connection: live) }
        _ = await waitUntil { self.reads(http) == 1 }
        for _ in 0..<60 { await clock.advance(60) }

        XCTAssertEqual(reads(http), 1, "an hour in the background: only the page's own open read")
        XCTAssertEqual(script.attempts, 0)
        XCTAssertEqual(clock.pendingCount, 0)
        page.cancel()
        await page.value
    }

    func testLeavingTheForegroundClosesTheSocketAfterTenSecondsAndStartsNoTimer() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await server(http, features: [Self.live])
        let socket = FakeLiveSocket()
        let (live, _) = connection([.socket(socket)])
        let model = OrganizationStreamsViewModel()
        let page = Task { @MainActor in await model.watch(session: session, connection: live) }
        _ = await waitUntil { self.reads(http) == 1 }
        await goLive(socket)
        _ = await waitUntil { self.reads(http) == 2 }
        await TestLiveClock.settle()

        live.setForeground(false)
        await clock.advance(11)
        XCTAssertTrue(socket.isClosed)
        let away = reads(http)
        for _ in 0..<60 { await clock.advance(60) }

        XCTAssertEqual(reads(http), away, "an hour away: not one request")
        XCTAssertEqual(clock.pendingCount, 0)
        page.cancel()
        await page.value
    }

    // MARK: The count

    func testTimedRequestsAMinuteOnTheOrganizationNowPlayingPage() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await server(http, features: [Self.live])
        let minutes = 5.0
        let model = OrganizationStreamsViewModel()

        // Before: the page's loop, `load` then sleep ten seconds. Five minutes is thirty more loads after the open.
        await model.load(session: session)
        let beforeOpen = reads(http)
        for _ in 0..<30 { await model.load(session: session) }
        let before = Double(reads(http) - beforeOpen) / minutes

        // After, socket live: the open and the connection's snapshot, then only what the socket says.
        let socket = FakeLiveSocket()
        let (live, _) = connection([.socket(socket)])
        let base = reads(http)
        let page = Task { @MainActor in await model.watch(session: session, connection: live) }
        _ = await waitUntil { self.reads(http) == base + 1 }
        await goLive(socket)
        _ = await waitUntil { self.reads(http) == base + 2 }
        await TestLiveClock.settle()
        let opened = reads(http)
        for _ in 0..<Int(minutes) { await clock.advance(60) }
        let afterLive = Double(reads(http) - opened) / minutes
        await clock.advance(2)
        socket.push(LiveFrames.event("org.streams"))
        let reacted = await waitUntil { self.reads(http) == opened + 1 }
        page.cancel()
        await page.value

        // After, a server that does not serve the channel: the same ten seconds as before.
        let other = FakeLiveSocket()
        let (notServed, _) = connection([.socket(other)])
        let notServedBase = reads(http)
        let paced = Task { @MainActor in await model.watch(session: session, connection: notServed) }
        _ = await waitUntil { self.reads(http) == notServedBase + 1 }
        other.push(LiveFrames.hello(["org.people"]))
        await TestLiveClock.settle()
        let notServedOpened = reads(http)
        for tick in 1...30 {
            await clock.advance(10)
            _ = await waitUntil { self.reads(http) == notServedOpened + tick }
        }
        let afterNotServed = Double(reads(http) - notServedOpened) / minutes
        paced.cancel()
        await paced.value

        // After, the socket cannot be had: at most one read a minute.
        let (down, _) = connection([.fail(.connection)])
        let downBase = reads(http)
        let offline = Task { @MainActor in await model.watch(session: session, connection: down) }
        _ = await waitUntil { self.reads(http) == downBase + 1 }
        await TestLiveClock.settle()
        for _ in 0..<Int(minutes) {
            await clock.advance(60)
            await TestLiveClock.settle()
            try? await Task.sleep(for: .milliseconds(150))
        }
        let afterDown = Double(reads(http) - downBase - 1) / minutes
        offline.cancel()
        await offline.value

        print("ORG-STREAMS timed requests per minute, page open \(Int(minutes)) minutes (iOS):")
        print("  before (10 s loop)                 \(before)")
        print("  after, socket live                 \(afterLive)   (one read per change: \(reacted))")
        print("  after, channel not served          \(afterNotServed)")
        print("  after, server without the socket   the 10 s loop, unchanged (no connection is opened)")
        print("  after, socket down                 \(afterDown)")
        XCTAssertEqual(before, 6.0, accuracy: 0.001)
        XCTAssertEqual(afterLive, 0.0, "no request is made on a timer while connected")
        XCTAssertTrue(reacted, "a change is read once")
        XCTAssertEqual(afterNotServed, 6.0, accuracy: 0.001, "a server that does not serve the channel keeps exactly the old pace")
        XCTAssertLessThanOrEqual(afterDown, 1.0, "with no socket: at most one read a minute")
    }
}
