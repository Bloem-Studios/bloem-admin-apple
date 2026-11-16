import XCTest
@testable import BloemAdmin

/// Widget wakes: how a delivery id names the channels that changed, which widgets reload for them, and that a
/// wake shows nothing and starts nothing.
final class PushWidgetWakeTests: XCTestCase {
    private let serverKinds = SiloWidgetKind.allCases.map(\.rawValue)

    // MARK: The wake id (the server's `{device_id}.widgets-{channels}-{unix seconds}`)

    func testTheServersOwnExampleReads() {
        let wire = PushWire(raw: "dev.widgets-nodes-requests-1763254800")
        XCTAssertEqual(wire?.deviceID, "dev")
        let wake = wire.flatMap(WidgetWake.init(wire:))
        XCTAssertEqual(wake?.channels, Set<WidgetChannel>([.nodes, .requests]))
        XCTAssertEqual(wake?.sentAt, Date(timeIntervalSince1970: 1_763_254_800))
    }

    func testOneChannelAndAllFour() {
        XCTAssertEqual(WidgetWake(deliveryID: "widgets-sessions-1763254800")?.channels, Set<WidgetChannel>([.sessions]))
        XCTAssertEqual(
            WidgetWake(deliveryID: "widgets-libraries-nodes-requests-sessions-1763254800")?.channels,
            Set<WidgetChannel>(WidgetChannel.allCases)
        )
    }

    func testTheChannelNamesAreTheServers() {
        XCTAssertEqual(WidgetChannel.allCases.map(\.rawValue).sorted(), ["libraries", "nodes", "requests", "sessions"])
        XCTAssertEqual(WidgetWake.reason, "widgets")
    }

    func testAChannelThisBuildDoesNotKnowIsDroppedNotMisread() {
        let wake = WidgetWake(deliveryID: "widgets-nodes-playlists-1763254800")
        XCTAssertEqual(wake?.channels, Set<WidgetChannel>([.nodes]))
        XCTAssertEqual(WidgetWake(deliveryID: "widgets-playlists-1763254800")?.channels, Set<WidgetChannel>(), "a valid wake that names nothing here")
    }

    func testAnythingThatIsNotAWakeIsNotOne() {
        let notWakes = [
            "", "abc", "0b8c4c1e-5f0e-5d2a-9a3e-aaaaaaaaaaaa", "widgets", "widgets-1763254800",
            "widgets-nodes", "widgets-nodes-soon", "widgets-nodes-17632548x0", "widgets--nodes-1763254800",
            "widget-nodes-1763254800", "Widgets-nodes-1763254800", "widgets-nodes-1763254800-",
        ]
        for id in notWakes { XCTAssertNil(WidgetWake(deliveryID: id), id.debugDescription) }
    }

    func testAWakeIsAWellFormedWireIdSoNothingElseNeedsParsing() {
        XCTAssertNotNil(PushWire(raw: "devabc123.widgets-libraries-nodes-requests-sessions-1763254800"))
    }

    // MARK: Which widgets show which channel

    func testEveryWidgetKindIsMappedAndTheKindIdsAreTheOnesTheAppReloads() {
        XCTAssertEqual(Set(SiloWidgetKind.allCases.map(\.rawValue)), Set(WidgetReload.kinds))
        for kind in SiloWidgetKind.allCases {
            XCTAssertFalse(WidgetPlacement.channels(forKind: kind).isEmpty, kind.rawValue)
        }
    }

    func testWhatEachWidgetShows() {
        XCTAssertEqual(WidgetPlacement.channels(forKind: .serverStatus), [.sessions, .requests], "stream count and requests waiting")
        XCTAssertEqual(WidgetPlacement.channels(forKind: .nowPlaying), [.sessions])
        XCTAssertEqual(WidgetPlacement.channels(forKind: .requests), [.requests])
        XCTAssertEqual(WidgetPlacement.channels(forKind: .libraries), [.libraries])
        XCTAssertEqual(WidgetPlacement.channels(forKind: .nodes), [.nodes])
    }

    func testAWakeReloadsTheWidgetsThatShowTheChangedChannelsAndNoOthers() {
        XCTAssertEqual(WidgetPlacement.kinds(reloadedBy: [.sessions]), [.serverStatus, .nowPlaying])
        XCTAssertEqual(WidgetPlacement.kinds(reloadedBy: [.requests]), [.serverStatus, .requests])
        XCTAssertEqual(WidgetPlacement.kinds(reloadedBy: [.libraries]), [.libraries])
        XCTAssertEqual(WidgetPlacement.kinds(reloadedBy: [.nodes]), [.nodes])
        XCTAssertEqual(WidgetPlacement.kinds(reloadedBy: [.nodes, .requests]), [.serverStatus, .requests, .nodes])
        XCTAssertEqual(WidgetPlacement.kinds(reloadedBy: Set<WidgetChannel>()), [])
    }

    // MARK: The report

    func testTheReportNamesTheChannelsOfThePlacedWidgetsSorted() {
        let report = WidgetPlacement.report(placedKinds: [SiloWidgetKind.requests.rawValue, SiloWidgetKind.nodes.rawValue])
        XCTAssertEqual(report, WidgetReport(placed: true, channels: [.requests, .nodes]))
        XCTAssertEqual(report.channelNames, ["nodes", "requests"])
    }

    func testTheServerStatusWidgetAloneFollowsStreamsAndRequests() {
        let report = WidgetPlacement.report(placedKinds: [SiloWidgetKind.serverStatus.rawValue])
        XCTAssertEqual(report.channelNames, ["requests", "sessions"])
    }

    func testNoWidgetPlacedIsReportedAsNone() {
        XCTAssertEqual(WidgetPlacement.report(placedKinds: []), .nothingPlaced)
        XCTAssertFalse(WidgetReport.nothingPlaced.placed)
        XCTAssertEqual(WidgetReport.nothingPlaced.channelNames, [])
    }

    func testAWidgetThatIsNotOursCountsForNothing() {
        XCTAssertEqual(WidgetPlacement.report(placedKinds: ["com.example.other"]), .nothingPlaced)
        XCTAssertEqual(
            WidgetPlacement.report(placedKinds: ["com.example.other", SiloWidgetKind.libraries.rawValue]).channelNames,
            ["libraries"]
        )
    }

    func testAReportNeverClaimsPlacedWithoutAChannel() {
        XCTAssertEqual(WidgetReport(placed: true, channels: []), .nothingPlaced)
        XCTAssertEqual(WidgetReport(placed: false, channels: [.nodes]), .nothingPlaced)
    }

    func testThePlacementReaderTurnsKindsIntoAReportAndUnknownIntoNil() async {
        let known = await FakeWidgetPlacements([SiloWidgetKind.nodes.rawValue]).report()
        XCTAssertEqual(known, WidgetReport(placed: true, channels: [.nodes]))
        let unknown = await FakeWidgetPlacements(nil).report()
        XCTAssertNil(unknown, "WidgetKit could not say: the server's record is left alone")
    }

    // MARK: The background handler

    private let registered = PushRegistration.fixture(device: "dev")

    private func handler(registrations: [PushRegistration]? = nil) -> (PushBackgroundHandler, FakeKindReloader) {
        let reloader = FakeKindReloader()
        let store = InMemoryPushRegistrations(registrations ?? [registered])
        return (PushBackgroundHandler(registrations: store, reloader: reloader), reloader)
    }

    func testAWakeReloadsExactlyTheAffectedKinds() {
        let (handler, reloader) = handler()
        let outcome = handler.handle(PushWire(raw: "dev.widgets-nodes-requests-1763254800"))

        XCTAssertEqual(outcome, .reloaded([.serverStatus, .requests, .nodes]))
        XCTAssertEqual(reloader.calls, [[.serverStatus, .requests, .nodes]])
    }

    func testEachChannelReloadsItsOwnWidgets() {
        for (channel, expected): (String, [SiloWidgetKind]) in [
            ("sessions", [.serverStatus, .nowPlaying]), ("requests", [.serverStatus, .requests]),
            ("libraries", [.libraries]), ("nodes", [.nodes]),
        ] {
            let (handler, reloader) = handler()
            handler.handle(PushWire(raw: "dev.widgets-\(channel)-1763254800"))
            XCTAssertEqual(reloader.calls, [expected], channel)
        }
    }

    func testAnAlertPushReloadsEveryWidgetBecauseItsKindIsNotInThePush() {
        let (handler, reloader) = handler()
        let outcome = handler.handle(PushWire(raw: "dev.0b8c4c1e-5f0e-5d2a-9a3e-aaaaaaaaaaaa"))
        XCTAssertEqual(outcome, .reloaded(SiloWidgetKind.allCases))
        XCTAssertEqual(reloader.calls, [SiloWidgetKind.allCases])
    }

    func testAWakeNamingNothingThisBuildHasReloadsNothing() {
        let (handler, reloader) = handler()
        XCTAssertEqual(handler.handle(PushWire(raw: "dev.widgets-playlists-1763254800")), .nothingToReload)
        XCTAssertEqual(reloader.calls, [])
    }

    func testAPushForADeviceThisPhoneDoesNotHaveIsIgnored() {
        let (handler, reloader) = handler()
        XCTAssertEqual(handler.handle(PushWire(raw: "someoneelse.widgets-nodes-1763254800")), .unknownDevice)
        XCTAssertEqual(reloader.calls, [])
    }

    func testARegistrationBeingRetiredIsIgnoredToo() {
        var retiring = registered
        retiring.isRetiring = true
        let (handler, reloader) = handler(registrations: [retiring])
        XCTAssertEqual(handler.handle(PushWire(raw: "dev.widgets-nodes-1763254800")), .unknownDevice)
        XCTAssertEqual(reloader.calls, [])
    }

    func testAPushThatIsNotOursIsIgnored() {
        let (handler, reloader) = handler()
        XCTAssertEqual(handler.handle(nil), .notOurs)
        XCTAssertEqual(reloader.calls, [])
    }

    func testAKeychainThatCannotBeReadYetIgnoresTheWake() {
        let store = InMemoryPushRegistrations([registered])
        store.setLocked(true)
        let reloader = FakeKindReloader()
        let outcome = PushBackgroundHandler(registrations: store, reloader: reloader).handle(PushWire(raw: "dev.widgets-nodes-1763254800"))
        XCTAssertEqual(outcome, .unknownDevice)
        XCTAssertEqual(reloader.calls, [])
    }

    func testTheWakeIsReadFromTheDictionaryIosHandsOver() {
        let userInfo: [AnyHashable: Any] = ["aps": ["content-available": 1], "bloem_delivery_id": "dev.widgets-libraries-1763254800"]
        let (handler, reloader) = handler()
        handler.handle(PushWire(userInfo: userInfo))
        XCTAssertEqual(reloader.calls, [[.libraries]])
    }

    // MARK: A wake shows nothing and starts nothing

    func testAWakeHasNoAlertSoTheExtensionIsNeverAskedToShowAnything() {
        // The relay's background_wake is `content-available` with no `alert` and no `mutable-content`, which is
        // what keeps the notification service extension out of it. The handler only ever sees such a payload.
        let userInfo: [AnyHashable: Any] = ["aps": ["content-available": 1], "bloem_delivery_id": "dev.widgets-nodes-1763254800"]
        let aps = userInfo["aps"] as? [String: Any]
        XCTAssertNil(aps?["alert"])
        XCTAssertNil(aps?["mutable-content"])
        XCTAssertNil(aps?["sound"])
        XCTAssertNil(aps?["badge"])
    }

    func testTheWakeCodeCannotPostANotificationOrOpenASocket() throws {
        let forbidden = [
            "UNUserNotificationCenter", "UNMutableNotificationContent", "UNNotificationRequest", "UNNotificationContent",
            "URLSessionWebSocketTask", "EventsSocket", "LiveConnection", "LiveHub", "URLSession", "SystemPushNotifier",
            "APIClient", "ServerStore",
        ]
        let sources = try SourceTree.sources(in: "BloemAdmin/Push")
        let wake = try XCTUnwrap(sources.first { $0.path == "PushWidgets.swift" })
        let core = try XCTUnwrap(try SourceTree.sources(in: "BloemAdmin/Push/Core").first { $0.path == "PushWidgetReport.swift" })
        for file in [wake, core] {
            for (index, line) in file.lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                for word in forbidden where code.contains(word) {
                    XCTFail("\(file.path):\(index + 1) mentions \(word)")
                }
            }
        }
    }

    func testTheAppDelegateHandsAWakeOnAndAnswersWithoutShowingAnything() throws {
        let delegate = try XCTUnwrap(try SourceTree.appSources().first { $0.path == "App/AppDelegate.swift" })
        let text = delegate.lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("didReceiveRemoteNotification userInfo"))
        XCTAssertTrue(text.contains("handleBackgroundPush"))
        let method = try XCTUnwrap(text.components(separatedBy: "didReceiveRemoteNotification userInfo").last?
            .components(separatedBy: "didFailToRegisterForRemoteNotificationsWithError").first)
        XCTAssertFalse(method.contains("UNUserNotificationCenter"), "a wake never shows anything")
        XCTAssertTrue(method.contains("completionHandler(.newData)") && method.contains("completionHandler(.noData)"))
    }

    // MARK: The background mode

    func testTheAppDeclaresTheRemoteNotificationBackgroundModeAlongsideFetch() throws {
        let yaml = try String(contentsOf: SourceTree.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let modes = try XCTUnwrap(yaml.components(separatedBy: "UIBackgroundModes:\n").dropFirst().first?
            .components(separatedBy: "BGTaskSchedulerPermittedIdentifiers").first)
        XCTAssertTrue(modes.contains("- fetch"))
        XCTAssertTrue(modes.contains("- remote-notification"))
        let info = try String(contentsOf: SourceTree.root.appendingPathComponent("BloemAdmin/Info.plist"), encoding: .utf8)
        XCTAssertTrue(info.contains("<string>remote-notification</string>"), "the generated Info.plist carries it")
        XCTAssertTrue(info.contains("<string>fetch</string>"))
    }

    func testTheExtensionIsNotGivenABackgroundModeItDoesNotNeed() throws {
        let info = try String(
            contentsOf: SourceTree.root.appendingPathComponent("BloemAdminNotificationService/Info.plist"), encoding: .utf8
        )
        XCTAssertFalse(info.contains("UIBackgroundModes"))
    }
}
