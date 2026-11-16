import UserNotifications
import XCTest
@testable import BloemAdmin

/// The notification service extension's whole decision, without an extension: find the server a push is for,
/// ask it for the text, and fall back to the generic text when it cannot answer.
final class PushNotificationProcessorTests: XCTestCase {
    private let registration = PushRegistration.fixture(name: "Silo Home")

    private func processor(
        registrations: [PushRegistration]? = nil, details: Bool = false, api: FakeDisplayAPI,
        budget: Duration = .seconds(8)
    ) -> PushNotificationProcessor {
        PushNotificationProcessor(
            registrations: InMemoryPushRegistrations(registrations ?? [registration]),
            settings: FakePushSettings(showsDetails: details), api: api, fetchBudget: budget
        )
    }

    func testTheServersTextReplacesTheRelaysGenericText() async {
        let api = FakeDisplayAPI(content: .content(PushSamples.content()))
        let plan = await processor(details: true, api: api).plan(for: PushSamples.wire)

        XCTAssertEqual(plan.title, "Sam requested Dune")
        XCTAssertEqual(plan.body, "3 waiting")
        XCTAssertEqual(plan.subtitle, "Silo Home")
        XCTAssertEqual(plan.categoryIdentifier, PushCategoryID.request)
    }

    func testItAsksTheServerThePushIsForWithThatDevicesTokenAndTheIdAsPushed() async {
        let other = PushRegistration.fixture(server: "lab", host: "lab.example.test", device: "dev2", token: "bad_other")
        let api = FakeDisplayAPI(content: .content(PushSamples.content()))
        _ = await processor(registrations: [registration, other], api: api).plan(for: PushWire(raw: "dev2.abc-1"))

        XCTAssertEqual(api.contentCalls, [
            FakeDisplayAPI.ContentCall(baseURL: URL(string: "https://lab.example.test")!, token: "bad_other", contentID: "dev2.abc-1")
        ])
    }

    func testWithDetailsOffTheFetchedTextStaysOutOfTheNotification() async {
        let api = FakeDisplayAPI(content: .content(PushSamples.content()))
        let plan = await processor(details: false, api: api).plan(for: PushSamples.wire)

        XCTAssertEqual(plan.title, "New request waiting")
        XCTAssertEqual(plan.body, "")
        XCTAssertEqual(plan.subtitle, "")
    }

    func testTheDetailsSettingIsReadFromTheSharedFileEachTime() async {
        let settings = FakePushSettings(showsDetails: false)
        let api = FakeDisplayAPI(content: .content(PushSamples.content()))
        let subject = PushNotificationProcessor(registrations: InMemoryPushRegistrations([registration]), settings: settings, api: api)

        let off = await subject.plan(for: PushSamples.wire)
        try? settings.save(PushSharedSettings(showDetailsOnLockScreen: true))
        let on = await subject.plan(for: PushSamples.wire)

        XCTAssertEqual(off.title, "New request waiting")
        XCTAssertEqual(on.title, "Sam requested Dune")
    }

    func testAServerThatCannotAnswerLeavesTheGenericText() async {
        for answer in [PushContentResult.failed, .gone] {
            let plan = await processor(api: FakeDisplayAPI(content: answer)).plan(for: PushSamples.wire)
            XCTAssertEqual(plan.title, "New notification", "\(answer)")
            XCTAssertEqual(plan.body, "Open the app to see it")
            XCTAssertEqual(plan.userInfo[PushUserInfo.serverID], "home")
        }
    }

    func testAServerThatAnswersTooSlowlyLeavesTheGenericTextWithinTheBudget() async {
        let api = FakeDisplayAPI(content: .content(PushSamples.content()), contentDelay: .seconds(30))
        let started = ContinuousClock.now
        let plan = await processor(details: true, api: api, budget: .milliseconds(100)).plan(for: PushSamples.wire)

        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        XCTAssertEqual(plan.title, "New notification")
    }

    func testAnAnswerThisBuildCannotShowLeavesTheGenericText() async {
        let unknown = PushContent(kind: "admin.disk_full", title: "Disk full")
        let plan = await processor(api: FakeDisplayAPI(content: .content(unknown))).plan(for: PushSamples.wire)
        XCTAssertEqual(plan.title, "New notification")
    }

    func testADeviceThisPhoneDoesNotHaveIsNotAskedAbout() async {
        let api = FakeDisplayAPI(content: .content(PushSamples.content()))
        let plan = await processor(api: api).plan(for: PushWire(raw: "someoneelse.abc-1"))

        XCTAssertEqual(api.contentCalls, [])
        XCTAssertEqual(plan.title, "New notification")
        XCTAssertNil(plan.userInfo[PushUserInfo.serverID])
    }

    func testARegistrationBeingRetiredIsNotUsed() async {
        var retiring = registration
        retiring.isRetiring = true
        let api = FakeDisplayAPI(content: .content(PushSamples.content()))
        let plan = await processor(registrations: [retiring], api: api).plan(for: PushSamples.wire)

        XCTAssertEqual(api.contentCalls, [], "signed out: the display token is not used again")
        XCTAssertEqual(plan.title, "New notification")
    }

    func testAPushThatIsNotOursIsGenericToo() async {
        let api = FakeDisplayAPI(content: .content(PushSamples.content()))
        let plan = await processor(api: api).plan(for: nil)
        XCTAssertEqual(api.contentCalls, [])
        XCTAssertEqual(plan.title, "New notification")
    }

    func testAKeychainThatCannotBeReadYetLeavesTheGenericText() async {
        let registrations = InMemoryPushRegistrations([registration])
        registrations.setLocked(true)
        let api = FakeDisplayAPI(content: .content(PushSamples.content()))
        let subject = PushNotificationProcessor(registrations: registrations, settings: FakePushSettings(), api: api)

        let plan = await subject.plan(for: PushSamples.wire)

        XCTAssertEqual(api.contentCalls, [])
        XCTAssertEqual(plan.title, "New notification")
    }

    func testItAppliesToTheNotificationTheRelaySent() async throws {
        let relay = UNMutableNotificationContent()
        relay.title = "Bloem"
        relay.body = "New notification available"
        relay.userInfo = [PushWire.deliveryKey: "dev1.abc-1"]
        let wire = PushWire(userInfo: relay.userInfo)
        let api = FakeDisplayAPI(content: .content(PushSamples.content()))

        let plan = await processor(details: true, api: api).plan(for: wire)
        plan.apply(to: relay)

        XCTAssertEqual(relay.title, "Sam requested Dune")
        XCTAssertFalse(relay.title.contains("Bloem") || relay.body.contains("Bloem"))
        XCTAssertEqual(relay.userInfo[PushWire.deliveryKey] as? String, "dev1.abc-1")
    }

    func testTheGenericTextNeverSaysBloem() async {
        let plan = await processor(api: FakeDisplayAPI(content: .failed)).plan(for: PushSamples.wire)
        XCTAssertFalse(plan.title.contains("Bloem"))
        XCTAssertFalse(plan.body.contains("Bloem"))
    }
}
