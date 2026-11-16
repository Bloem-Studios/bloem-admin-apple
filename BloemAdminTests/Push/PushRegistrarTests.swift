import XCTest
@testable import BloemAdmin

/// The token lifecycle: when the phone registers with a saved server, when it does not, what Settings says
/// about each server, and when iOS is asked for permission.
@MainActor
final class PushRegistrarTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        (defaults, suite) = AlertTestDefaults.make()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private let home = AdminServer.fixture("home", name: "Silo Home", host: "home.example.test")
    private let lab = AdminServer.fixture("lab", name: "Lab", host: "lab.example.test")

    private struct Rig {
        let registrar: PushRegistrar
        let gateway: FakePushGateway
        let registrations: InMemoryPushRegistrations
        let preferences: PushPreferences
        let authorizer: FakeAuthorizer
        let api: FakeDisplayAPI
        let remoteRegistrations: PushCallCounter
        let clock: AlertTestClock
    }

    private func rig(
        servers: [AdminServer]? = nil, signedIn: Set<String> = ["home"], permission: NotificationPermission = .allowed,
        apnsToken: String? = "apns-1", registrations: [PushRegistration] = [], api: FakeDisplayAPI = FakeDisplayAPI(),
        budget: Duration = .seconds(5), widgets: FakeWidgetPlacements? = nil
    ) -> Rig {
        let list = servers ?? [home]
        let gateway = FakePushGateway(signedIn: signedIn)
        let store = InMemoryPushRegistrations(registrations)
        let preferences = PushPreferences(defaults: defaults)
        preferences.apnsToken = apnsToken
        let authorizer = FakeAuthorizer(permission)
        let counter = PushCallCounter()
        let clock = AlertTestClock()
        let registrar = PushRegistrar(
            servers: { list }, gateway: gateway, registrations: store, preferences: preferences,
            authorizer: authorizer, api: api, apnsEnvironment: "sandbox",
            registerForRemoteNotifications: { counter.bump() }, unregisterBudget: budget, now: clock.reader,
            widgetReport: { await widgets?.report() }
        )
        return Rig(
            registrar: registrar, gateway: gateway, registrations: store, preferences: preferences,
            authorizer: authorizer, api: api, remoteRegistrations: counter, clock: clock
        )
    }

    // MARK: A plain Silo server

    func testAPlainSiloServerIsNeverRegisteredWithAndSaysSoPlainly() async {
        let rig = rig()
        rig.gateway.capabilityAnswers["home"] = .success(nil)

        await rig.registrar.reconcile(.changed)

        XCTAssertEqual(rig.gateway.registerCalls.count, 0)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .plainSilo)
        XCTAssertEqual(rig.registrations.load(), .found([]))
        XCTAssertFalse(PushSettingsModel.text(for: .plainSilo).localizedCaseInsensitiveContains("error"))
        XCTAssertFalse(PushSettingsModel.text(for: .plainSilo).localizedCaseInsensitiveContains("couldn't"))
    }

    func testAPlainSiloServerIsAskedOnlyForTheAnswerTheAppAlreadyHas() async {
        let rig = rig()
        rig.gateway.capabilityAnswers["home"] = .success(nil)
        rig.preferences.setStatus(.plainSilo, serverID: "home")

        for reason in [PushRegistrar.Reason.changed, .foreground, .foreground, .token] {
            await rig.registrar.reconcile(reason)
        }

        XCTAssertTrue(rig.gateway.capabilityCalls.allSatisfy { !$0.fresh }, "a plain Silo server is asked once per session, like everywhere else")
    }

    // MARK: A Bloem server without push yet (production, before the deploy)

    func testABloemServerWithoutPushIsNotAvailableYetWithNoError() async {
        let rig = rig()
        rig.gateway.capabilityAnswers["home"] = .success(FakePushGateway.withoutPush)

        await rig.registrar.reconcile(.changed)

        XCTAssertEqual(rig.preferences.status(serverID: "home"), .notAvailableYet)
        XCTAssertEqual(rig.gateway.registerCalls.count, 0)
        XCTAssertFalse(PushSettingsModel.text(for: .notAvailableYet).localizedCaseInsensitiveContains("couldn't"))
    }

    func testARegistrationTheServerAnswers404IsNotAvailableYetAndTriedAgainAtTheNextForeground() async {
        let rig = rig()
        rig.gateway.registerResult = .failure(APIError(statusCode: 404, message: "Not found"))

        await rig.registrar.reconcile(.signedIn(serverID: "home"))
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .notAvailableYet)
        XCTAssertEqual(rig.registrations.load(), .found([]), "nothing is kept for a registration the server refused")
        XCTAssertEqual(rig.gateway.registerCalls.count, 1)

        // Deployed meanwhile.
        rig.gateway.registerResult = .success(PushRegistered(deviceID: "dev1", displayToken: "bad_token-1"))
        await rig.registrar.reconcile(.foreground)

        XCTAssertEqual(rig.gateway.registerCalls.count, 2)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .registered)
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.deviceID, "dev1")
    }

    func testAServerWithPushTurnedOffAnswers503AndIsNotAvailableYetToo() async {
        let rig = rig()
        rig.gateway.registerResult = .failure(APIError(statusCode: 503, code: "admin_push_unavailable", message: "off"))
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .notAvailableYet)
    }

    func testAServerThatCouldNotOfferPushIsAskedAgainAtASignInAndAfterTenMinutes() async {
        let rig = rig()
        rig.gateway.capabilityAnswers["home"] = .success(FakePushGateway.withoutPush)
        await rig.registrar.reconcile(.changed)
        await rig.registrar.reconcile(.foreground)
        XCTAssertTrue(rig.gateway.capabilityCalls.allSatisfy { !$0.fresh }, "a foreground right away does not ask again")

        rig.clock.advance(11 * 60)
        await rig.registrar.reconcile(.foreground)
        XCTAssertEqual(rig.gateway.capabilityCalls.last?.fresh, true)

        rig.gateway.capabilityAnswers["home"] = .success(FakePushGateway.withPush)
        await rig.registrar.reconcile(.signedIn(serverID: "home"))
        XCTAssertEqual(rig.gateway.capabilityCalls.last?.fresh, true)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .registered, "a server that gained push is noticed")
    }

    func testAnAdministratorOnlyServerSaysSoAndKeepsTrying() async {
        let rig = rig()
        rig.gateway.registerResult = .failure(APIError(statusCode: 403, code: "admin_required", message: "no"))
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .needsAdminAccount)
    }

    func testAnyOtherFailureIsAFailureTheAppRetries() async {
        let rig = rig()
        rig.gateway.registerResult = .failure(APIError(statusCode: 500, message: "boom"))
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .failed)
        rig.gateway.registerResult = .failure(URLError(.notConnectedToInternet))
        await rig.registrar.reconcile(.foreground)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .failed)
        XCTAssertEqual(rig.gateway.registerCalls.count, 2)
    }

    func testAServerThatCouldNotBeAskedKeepsWhatWasKnown() async {
        let rig = rig()
        rig.preferences.setStatus(.registered, serverID: "home")
        rig.gateway.capabilityAnswers["home"] = .failure(URLError(.timedOut))
        await rig.registrar.reconcile(.foreground)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .registered)
    }

    // MARK: Registering

    func testItRegistersWithTheFieldsTheServerContractNames() async throws {
        let rig = rig()
        rig.preferences.setKind(.scanFailed, enabled: false, serverID: "home")
        rig.preferences.setKind(.serverUp, enabled: false, serverID: "home")
        rig.preferences.setKind(.backupFailed, enabled: false, serverID: "home")

        await rig.registrar.reconcile(.changed)

        let request = try XCTUnwrap(rig.gateway.registerCalls.first?.request)
        XCTAssertEqual(request.platform, "apple")
        XCTAssertEqual(request.token, "apns-1")
        XCTAssertEqual(request.apnsEnvironment, "sandbox")
        XCTAssertEqual(request.apnsTopic, "com.bloemstudios.admin")
        XCTAssertEqual(request.installationID, rig.preferences.installationID)
        XCTAssertEqual(request.disabledKinds, ["admin.backup_failed", "admin.scan_failed"], "only server kinds, sorted: the local kinds never leave the phone")
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .registered)
    }

    func testTheRegistrationIsTiedToItsServerAndAccount() async throws {
        let rig = rig()
        rig.gateway.accounts["home"] = "7/inc-1"
        rig.gateway.registerResult = .success(PushRegistered(deviceID: "devX", displayToken: "bad_X"))

        await rig.registrar.reconcile(.changed)

        let saved = try XCTUnwrap(rig.registrations.registration(serverID: "home"))
        XCTAssertEqual(saved.deviceID, "devX")
        XCTAssertEqual(saved.displayToken, "bad_X")
        XCTAssertEqual(saved.accountKey, "7/inc-1")
        XCTAssertEqual(saved.baseURL, home.baseURL)
        XCTAssertEqual(saved.serverName, "Silo Home")
        XCTAssertEqual(saved.tokenHash, PushRegistrar.hash("apns-1"))
        XCTAssertEqual(saved.registeredAt, rig.clock.now)
    }

    func testTheInstallationIdIsTheSameAcrossPasses() async {
        let rig = rig()
        await rig.registrar.reconcile(.changed)
        await rig.registrar.reconcile(.signedIn(serverID: "home"))
        let ids = Set(rig.gateway.registerCalls.map { $0.request.installationID })
        XCTAssertEqual(ids.count, 1)
        XCTAssertGreaterThanOrEqual(ids.first?.count ?? 0, 8)
    }

    func testItDoesNotRegisterAgainWhileTheRegistrationIsCurrent() async {
        let rig = rig()
        await rig.registrar.reconcile(.changed)
        await rig.registrar.reconcile(.foreground)
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(rig.gateway.registerCalls.count, 1, "registering replaces the display token, so it is not done for nothing")
    }

    func testANewApnsTokenRegistersAgain() async {
        let rig = rig()
        await rig.registrar.reconcile(.changed)
        rig.preferences.apnsToken = "apns-2"
        await rig.registrar.reconcile(.token)

        XCTAssertEqual(rig.gateway.registerCalls.map { $0.request.token }, ["apns-1", "apns-2"])
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.tokenHash, PushRegistrar.hash("apns-2"))
    }

    func testASignInRegistersAgainForWhoeverSignedIn() async {
        let rig = rig()
        await rig.registrar.reconcile(.changed)
        await rig.registrar.reconcile(.signedIn(serverID: "home"))
        XCTAssertEqual(rig.gateway.registerCalls.count, 2)
        await rig.registrar.reconcile(.foreground)
        XCTAssertEqual(rig.gateway.registerCalls.count, 2, "and only once per sign-in")
    }

    func testAnotherAccountSigningInMovesTheRegistrationEvenWithoutASignInEvent() async {
        let rig = rig()
        rig.gateway.accounts["home"] = "7"
        await rig.registrar.reconcile(.changed)
        rig.gateway.accounts["home"] = "9"
        await rig.registrar.reconcile(.changed)

        XCTAssertEqual(rig.gateway.registerCalls.count, 2)
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.accountKey, "9")
    }

    func testARegistrationAWeekOldIsRefreshed() async {
        let rig = rig()
        await rig.registrar.reconcile(.changed)
        rig.clock.advance(6 * 24 * 3600)
        await rig.registrar.reconcile(.foreground)
        XCTAssertEqual(rig.gateway.registerCalls.count, 1)
        rig.clock.advance(2 * 24 * 3600)
        await rig.registrar.reconcile(.foreground)
        XCTAssertEqual(rig.gateway.registerCalls.count, 2)
    }

    func testARenamedServerUpdatesTheNameTheExtensionShowsWithoutRegisteringAgain() async {
        let rig = rig(registrations: [.fixture(server: "home", name: "Old name", host: "home.example.test")])
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(rig.gateway.registerCalls.count, 0)
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.serverName, "Silo Home")
    }

    func testEachSavedServerHasItsOwnRegistration() async {
        let rig = rig(servers: [home, lab], signedIn: ["home", "lab"])
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(Set(rig.gateway.registerCalls.map { $0.serverID }), ["home", "lab"])
        XCTAssertEqual(rig.registrations.load().servers, ["home", "lab"])
    }

    func testAServerThatIsSignedOutIsLeftAloneAndSaysSo() async {
        let rig = rig(servers: [home, lab], signedIn: ["home"])
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(rig.gateway.capabilityCalls.map { $0.serverID }, ["home"])
        XCTAssertEqual(rig.preferences.status(serverID: "lab"), .signedOut)
    }

    // MARK: Permission

    func testWithoutPermissionNothingIsRegisteredAndSettingsSaysToAllowIt() async {
        let rig = rig(permission: .denied)
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(rig.gateway.registerCalls.count, 0)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .needsPermission)
        XCTAssertEqual(rig.authorizer.requests, 0, "a refusal is never asked about again")
    }

    func testWithoutAnApnsTokenYetTheAppAsksIosForOneAndWaits() async {
        let rig = rig(apnsToken: nil)
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .waitingForToken)
        XCTAssertEqual(rig.remoteRegistrations.count, 1)
        XCTAssertEqual(rig.gateway.registerCalls.count, 0)
    }

    func testWithATokenTheAppDoesNotAskIosAgainBecauseEachAskAnswersWithAnotherPass() async {
        let rig = rig(apnsToken: "apns-1")
        for reason in [PushRegistrar.Reason.changed, .foreground, .token, .signedIn(serverID: "home")] {
            await rig.registrar.reconcile(reason)
        }
        XCTAssertEqual(rig.remoteRegistrations.count, 0)
    }

    func testPermissionIsAskedOnceWhenTheFirstPageHasLoadedForAServerThatCanPush() async {
        let rig = rig(permission: .notDetermined, apnsToken: nil)

        await rig.registrar.reconcile(.firstPageLoaded)

        XCTAssertEqual(rig.authorizer.requests, 1)
        XCTAssertTrue(rig.preferences.permissionAsked)
        XCTAssertEqual(rig.remoteRegistrations.count, 1, "granted: iOS is asked for this phone's token")
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .waitingForToken)
    }

    func testASignInAloneNeverAsksForPermission() async {
        let rig = rig(permission: .notDetermined, apnsToken: nil)

        await rig.registrar.reconcile(.signedIn(serverID: "home"))

        XCTAssertEqual(rig.authorizer.requests, 0, "straight after a sign-in nothing is asked")
        XCTAssertFalse(rig.preferences.permissionAsked)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .needsPermission)
    }

    func testTheFirstPageLoadingAfterASignInIsWhatAsks() async {
        let rig = rig(permission: .notDetermined, apnsToken: nil)
        await rig.registrar.reconcile(.signedIn(serverID: "home"))
        XCTAssertEqual(rig.authorizer.requests, 0)

        await rig.registrar.reconcile(.firstPageLoaded)

        XCTAssertEqual(rig.authorizer.requests, 1)
    }

    func testAnotherSignInAfterTheFirstPageHasLoadedDoesNotAskEither() async {
        let rig = rig(permission: .notDetermined, apnsToken: nil)
        rig.gateway.capabilityAnswers["home"] = .success(FakePushGateway.withoutPush)
        await rig.registrar.reconcile(.firstPageLoaded)
        XCTAssertEqual(rig.authorizer.requests, 0, "no server can push, so nothing is asked")

        rig.gateway.capabilityAnswers["home"] = .success(FakePushGateway.withPush)
        await rig.registrar.reconcile(.signedIn(serverID: "home"))

        XCTAssertEqual(rig.authorizer.requests, 0, "a later sign-in is not the moment")
    }

    func testPermissionIsNeverAskedTwice() async {
        let rig = rig(permission: .notDetermined, apnsToken: nil)
        await rig.registrar.reconcile(.firstPageLoaded)
        await rig.registrar.reconcile(.firstPageLoaded)
        XCTAssertEqual(rig.authorizer.requests, 1)
    }

    func testPermissionIsNeverAskedAtLaunchOnForegroundOrWhenSomethingChanges() async {
        for reason in [PushRegistrar.Reason.launch, .foreground, .changed, .token, .signedIn(serverID: "home")] {
            let rig = rig(permission: .notDetermined, apnsToken: nil)
            await rig.registrar.reconcile(reason)
            XCTAssertEqual(rig.authorizer.requests, 0, "\(reason)")
            XCTAssertEqual(rig.preferences.status(serverID: "home"), .needsPermission)
            XCTAssertFalse(rig.preferences.permissionAsked)
        }
    }

    func testPermissionIsNotAskedForAServerThatCannotPush() async {
        for answer in [Result<BloemCapabilities?, Error>.success(nil), .success(FakePushGateway.withoutPush)] {
            let rig = rig(permission: .notDetermined)
            rig.gateway.capabilityAnswers["home"] = answer
            await rig.registrar.reconcile(.firstPageLoaded)
            XCTAssertEqual(rig.authorizer.requests, 0)
        }
    }

    func testAPermissionAnswerDeniedStaysDeniedAndExplainsHowToAllowIt() async {
        let rig = rig(permission: .notDetermined)
        let refuser = FakeAuthorizer(.notDetermined, answer: false)
        let server = home
        let registrar = PushRegistrar(
            servers: { [server] }, gateway: rig.gateway, registrations: rig.registrations, preferences: rig.preferences,
            authorizer: refuser, api: rig.api, apnsEnvironment: "sandbox", registerForRemoteNotifications: {}
        )
        await registrar.reconcile(.firstPageLoaded)
        XCTAssertEqual(refuser.requests, 1)
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .needsPermission)
        XCTAssertEqual(rig.gateway.registerCalls.count, 0)
    }

    func testAPromptWaitsForAServerThatCouldNotBeAskedYet() async {
        let rig = rig(permission: .notDetermined, apnsToken: nil)
        rig.gateway.capabilityAnswers["home"] = .failure(URLError(.timedOut))
        await rig.registrar.reconcile(.firstPageLoaded)
        XCTAssertEqual(rig.authorizer.requests, 0)

        rig.gateway.capabilityAnswers["home"] = .success(FakePushGateway.withPush)
        await rig.registrar.reconcile(.foreground)
        XCTAssertEqual(rig.authorizer.requests, 1, "still the first page's one moment")
    }

    // MARK: Switches

    func testASwitchIsKeptHereAndSentToTheServer() async {
        let rig = rig()
        await rig.registrar.reconcile(.changed)
        await rig.registrar.setKind(.scanFailed, enabled: false, server: home)

        XCTAssertFalse(rig.preferences.isEnabled(.scanFailed, serverID: "home"))
        XCTAssertEqual(rig.gateway.kindCalls.count, 1)
        XCTAssertEqual(rig.gateway.kindCalls.first?.deviceID, "dev1")
        XCTAssertEqual(rig.gateway.kindCalls.first?.kinds, ["admin.scan_failed": false])
    }

    func testALocalKindNeverLeavesThePhone() async {
        let rig = rig()
        await rig.registrar.reconcile(.changed)
        await rig.registrar.setKind(.serverUp, enabled: false, server: home)
        XCTAssertFalse(rig.preferences.isEnabled(.serverUp, serverID: "home"))
        XCTAssertEqual(rig.gateway.kindCalls.count, 0)
    }

    func testASwitchForAServerNotRegisteredYetTravelsWithTheRegistration() async {
        let rig = rig(permission: .denied)
        await rig.registrar.setKind(.nodeOffline, enabled: false, server: home)
        XCTAssertEqual(rig.gateway.kindCalls.count, 0)
        XCTAssertEqual(rig.preferences.disabledRemoteKinds(serverID: "home"), ["admin.node_offline"])
    }

    func testASwitchThatCouldNotBeSentIsSentWithTheNextRegistration() async {
        let rig = rig()
        await rig.registrar.reconcile(.changed)
        rig.gateway.setKindsError = URLError(.notConnectedToInternet)

        await rig.registrar.setKind(.pluginFailed, enabled: false, server: home)
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.needsResync, true)

        rig.gateway.setKindsError = nil
        await rig.registrar.reconcile(.foreground)
        XCTAssertEqual(rig.gateway.registerCalls.count, 2)
        XCTAssertEqual(rig.gateway.registerCalls.last?.request.disabledKinds, ["admin.plugin_failed"])
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.needsResync, false)
    }

    // MARK: Sign-out and removal

    func testSigningOutStopsPushesWithTheDisplayTokenAndForgetsTheRegistration() async {
        let api = FakeDisplayAPI(retire: .retired)
        let rig = rig(registrations: [.fixture()], api: api)
        rig.preferences.setStatus(.registered, serverID: "home")

        await rig.registrar.unregister(serverID: "home")

        XCTAssertEqual(api.retireCalls, [FakeDisplayAPI.RetireCall(baseURL: home.baseURL, token: "bad_token-1", deviceID: "dev1")])
        XCTAssertEqual(rig.registrations.load(), .found([]))
    }

    func testTheServerNoLongerKnowingTheDeviceIsAsGoodAsRetiring() async {
        let rig = rig(registrations: [.fixture()], api: FakeDisplayAPI(retire: .gone))
        await rig.registrar.unregister(serverID: "home")
        XCTAssertEqual(rig.registrations.load(), .found([]))
    }

    func testSigningOutNeverWaitsLongerThanTheBudgetOnAServerThatDoesNotAnswer() async {
        let api = FakeDisplayAPI(retire: .retired, retireDelay: .seconds(60))
        let rig = rig(registrations: [.fixture()], api: api, budget: .milliseconds(100))
        let started = ContinuousClock.now

        await rig.registrar.unregister(serverID: "home")

        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
        XCTAssertEqual(api.retireCalls.count, 1)
    }

    func testTheExtensionStopsUsingARegistrationTheServerHasNotConfirmedStopping() async {
        let api = FakeDisplayAPI(retire: .failed)
        let rig = rig(registrations: [.fixture()], api: api)

        await rig.registrar.unregister(serverID: "home")

        let kept = rig.registrations.registration(serverID: "home")
        XCTAssertEqual(kept?.isRetiring, true)
        XCTAssertEqual(kept?.retireAttempts, 1)
        XCTAssertNil(rig.registrations.registration(deviceID: "dev1"), "so a push for it is no longer answered with names")
    }

    func testAServerThatWasOfflineIsToldAtALaterPass() async {
        let api = FakeDisplayAPI(retire: .failed)
        let rig = rig(signedIn: [], registrations: [.fixture()], api: api)
        await rig.registrar.unregister(serverID: "home")
        XCTAssertNotNil(rig.registrations.registration(serverID: "home"))

        api.answerRetire(with: .retired)
        await rig.registrar.reconcile(.foreground)

        XCTAssertEqual(api.retireCalls.count, 2)
        XCTAssertEqual(rig.registrations.load(), .found([]))
    }

    func testARegistrationThatCannotBeRetiredIsGivenUpOnAfterAFewTries() async {
        let api = FakeDisplayAPI(retire: .failed)
        let rig = rig(signedIn: [], registrations: [.fixture()], api: api)
        await rig.registrar.unregister(serverID: "home")
        for _ in 1..<PushRegistrar.maxRetireAttempts {
            XCTAssertNotNil(rig.registrations.registration(serverID: "home"))
            await rig.registrar.reconcile(.foreground)
        }
        XCTAssertEqual(rig.registrations.load(), .found([]))
        XCTAssertEqual(api.retireCalls.count, PushRegistrar.maxRetireAttempts)
    }

    func testARemovedServersRegistrationIsStoppedAtItsOwnAddress() async {
        let gone = PushRegistration.fixture(server: "gone", host: "gone.example.test", device: "devG", token: "bad_gone")
        let api = FakeDisplayAPI(retire: .retired)
        let rig = rig(registrations: [gone], api: api)

        await rig.registrar.reconcile(.changed)

        XCTAssertEqual(api.retireCalls, [FakeDisplayAPI.RetireCall(baseURL: URL(string: "https://gone.example.test")!, token: "bad_gone", deviceID: "devG")])
        XCTAssertNil(rig.registrations.registration(serverID: "gone"))
        XCTAssertNotNil(rig.registrations.registration(serverID: "home"), "the server that is still saved is registered as usual")
    }

    func testSigningInAgainAfterSigningOutRegistersFresh() async {
        let api = FakeDisplayAPI(retire: .retired)
        let rig = rig(api: api)
        await rig.registrar.reconcile(.changed)
        await rig.registrar.unregister(serverID: "home")
        rig.gateway.registerResult = .success(PushRegistered(deviceID: "dev2", displayToken: "bad_token-2"))

        await rig.registrar.reconcile(.signedIn(serverID: "home"))

        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.deviceID, "dev2")
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.isRetiring, false)
    }

    // MARK: Forgetting what is no longer saved

    func testWhatIsKeptForARemovedServerIsForgotten() async {
        let rig = rig(servers: [home])
        rig.preferences.setKind(.scanFailed, enabled: false, serverID: "lab")
        rig.preferences.setStatus(.registered, serverID: "lab")

        await rig.registrar.reconcile(.changed)

        XCTAssertTrue(rig.preferences.isEnabled(.scanFailed, serverID: "lab"))
        XCTAssertEqual(rig.preferences.status(serverID: "lab"), .unknown)
    }

    // MARK: Widget wakes (the report of which widgets are placed)

    private func placed(_ kinds: SiloWidgetKind...) -> FakeWidgetPlacements {
        FakeWidgetPlacements(Set(kinds.map(\.rawValue)))
    }

    func testTheRegistrationReportsWhichWidgetsArePlacedAndWhatTheyShow() async throws {
        let rig = rig(widgets: placed(.nowPlaying, .nodes))
        // A server that does wakes answers with what it now holds.
        rig.gateway.registerResult = .success(PushRegistered(
            deviceID: "dev1", displayToken: "bad_token-1", widgets: WidgetReport(placed: true, channels: [.nodes, .sessions])
        ))

        await rig.registrar.reconcile(.changed)

        let request = try XCTUnwrap(rig.gateway.registerCalls.first?.request)
        XCTAssertEqual(request.widgetsPlaced, true)
        XCTAssertEqual(request.widgetChannels, ["nodes", "sessions"])
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.widgetReport, WidgetReport(placed: true, channels: [.nodes, .sessions]))
    }

    func testNoWidgetPlacedIsReportedAsNotPlacedWithNoChannels() async throws {
        let rig = rig(widgets: FakeWidgetPlacements([]))
        await rig.registrar.reconcile(.changed)
        let request = try XCTUnwrap(rig.gateway.registerCalls.first?.request)
        XCTAssertEqual(request.widgetsPlaced, false)
        XCTAssertNil(request.widgetChannels, "channels are sent only when something is placed")
    }

    func testWhenWidgetKitCannotSayNothingIsReportedAndTheServersRecordIsLeftAlone() async throws {
        let rig = rig(widgets: FakeWidgetPlacements(nil))
        await rig.registrar.reconcile(.changed)
        let request = try XCTUnwrap(rig.gateway.registerCalls.first?.request)
        XCTAssertNil(request.widgetsPlaced)
        XCTAssertNil(request.widgetChannels)
        XCTAssertEqual(rig.gateway.widgetCalls.count, 0)
    }

    func testAWidgetAddedLaterIsReportedAtTheNextForegroundWithoutRegisteringAgain() async throws {
        let widgets = FakeWidgetPlacements([])
        let rig = rig(widgets: widgets)
        rig.gateway.registerResult = .success(PushRegistered(deviceID: "dev1", displayToken: "bad_token-1", widgets: .nothingPlaced))
        await rig.registrar.reconcile(.changed)

        widgets.kinds = [SiloWidgetKind.requests.rawValue]
        await rig.registrar.reconcile(.foreground)

        XCTAssertEqual(rig.gateway.registerCalls.count, 1, "reporting a widget does not replace the display token")
        XCTAssertEqual(rig.gateway.widgetCalls.count, 1)
        XCTAssertEqual(rig.gateway.widgetCalls.first?.deviceID, "dev1")
        XCTAssertEqual(rig.gateway.widgetCalls.first?.report, WidgetReport(placed: true, channels: [.requests]))
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.widgetReport, WidgetReport(placed: true, channels: [.requests]))
    }

    func testRemovingTheLastWidgetReportsNotPlaced() async throws {
        let widgets = placed(.libraries)
        let rig = rig(widgets: widgets)
        rig.gateway.registerResult = .success(PushRegistered(deviceID: "dev1", displayToken: "bad_token-1", widgets: WidgetReport(placed: true, channels: [.libraries])))
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(rig.gateway.widgetCalls.count, 0, "what the server holds already matches")

        widgets.kinds = []
        await rig.registrar.reconcile(.foreground)

        XCTAssertEqual(rig.gateway.widgetCalls.map { $0.report }, [.nothingPlaced])
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.widgetReport, WidgetReport.nothingPlaced)
    }

    func testAnUnchangedReportIsNotSentAgain() async {
        let widgets = placed(.nodes)
        let rig = rig(widgets: widgets)
        rig.gateway.registerResult = .success(PushRegistered(deviceID: "dev1", displayToken: "bad_token-1", widgets: WidgetReport(placed: true, channels: [.nodes])))
        for reason in [PushRegistrar.Reason.changed, .foreground, .foreground, .token, .launch] {
            await rig.registrar.reconcile(reason)
        }
        XCTAssertEqual(rig.gateway.widgetCalls.count, 0)
        XCTAssertEqual(rig.gateway.registerCalls.count, 1)
    }

    func testAReportThatFailedIsTriedAgainAtTheNextPass() async {
        let widgets = FakeWidgetPlacements([])
        let rig = rig(widgets: widgets)
        rig.gateway.registerResult = .success(PushRegistered(deviceID: "dev1", displayToken: "bad_token-1", widgets: .nothingPlaced))
        await rig.registrar.reconcile(.changed)
        widgets.kinds = [SiloWidgetKind.nodes.rawValue]

        rig.gateway.setWidgetsError = URLError(.notConnectedToInternet)
        await rig.registrar.reconcile(.foreground)
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.widgetReport, WidgetReport.nothingPlaced, "the record still says what the server holds")

        rig.gateway.setWidgetsError = nil
        await rig.registrar.reconcile(.foreground)
        XCTAssertEqual(rig.gateway.widgetCalls.count, 2)
        XCTAssertEqual(rig.registrations.registration(serverID: "home")?.widgetReport, WidgetReport(placed: true, channels: [.nodes]))
    }

    func testAServerWhoseAnswerHasNoWidgetFieldsDoesNotSendWakesAndIsNeverTold() async {
        let rig = rig(widgets: placed(.nodes))
        rig.gateway.registerResult = .success(PushRegistered(deviceID: "dev1", displayToken: "bad_token-1"))
        await rig.registrar.reconcile(.changed)
        await rig.registrar.reconcile(.foreground)
        XCTAssertNil(rig.registrations.registration(serverID: "home")?.widgetReport)
        XCTAssertEqual(rig.gateway.widgetCalls.count, 0)
    }

    func testAServerThatRefusesTheReportAsMissingIsLeftAloneFromThenOn() async {
        let widgets = FakeWidgetPlacements([])
        let rig = rig(widgets: widgets)
        rig.gateway.registerResult = .success(PushRegistered(deviceID: "dev1", displayToken: "bad_token-1", widgets: .nothingPlaced))
        await rig.registrar.reconcile(.changed)
        widgets.kinds = [SiloWidgetKind.requests.rawValue]
        rig.gateway.setWidgetsError = APIError(statusCode: 404, message: "Not found")

        await rig.registrar.reconcile(.foreground)
        await rig.registrar.reconcile(.foreground)

        XCTAssertEqual(rig.gateway.widgetCalls.count, 1, "asked once, then never again")
        XCTAssertEqual(rig.preferences.status(serverID: "home"), .registered, "and it is not shown as an error")
    }

    func testNothingIsReportedToAServerThatCannotPush() async {
        let rig = rig(widgets: placed(.nodes))
        rig.gateway.capabilityAnswers["home"] = .success(nil)
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(rig.gateway.registerCalls.count, 0)
        XCTAssertEqual(rig.gateway.widgetCalls.count, 0)
    }

    func testAWidgetReportIsNotSentToARegistrationBeingRetired() async {
        var retiring = PushRegistration.fixture()
        retiring.isRetiring = true
        retiring.widgetReport = WidgetReport.nothingPlaced
        let rig = rig(registrations: [retiring], widgets: placed(.nodes))
        rig.gateway.registerResult = .failure(APIError(statusCode: 503, message: "off"))
        await rig.registrar.reconcile(.changed)
        XCTAssertEqual(rig.gateway.widgetCalls.count, 0)
    }

    func testTheReportIsReadOncePerPassAndOnlyWhenSomeServerCanPush() async {
        final class Reads: @unchecked Sendable {
            private let lock = NSLock()
            private var count_ = 0
            var count: Int { lock.withLock { count_ } }
            func bump() { lock.withLock { count_ += 1 } }
        }
        let reads = Reads()
        let server = home
        for canPush in [true, false] {
            let gateway = FakePushGateway()
            gateway.capabilityAnswers["home"] = .success(canPush ? FakePushGateway.withPush : nil)
            let registrar = PushRegistrar(
                servers: { [server] }, gateway: gateway, registrations: InMemoryPushRegistrations(),
                preferences: PushPreferences(defaults: defaults), authorizer: FakeAuthorizer(.allowed), api: FakeDisplayAPI(),
                apnsEnvironment: "sandbox", registerForRemoteNotifications: {},
                widgetReport: { reads.bump(); return WidgetReport.nothingPlaced }
            )
            let before = reads.count
            PushPreferences(defaults: defaults).apnsToken = "apns-1"
            await registrar.reconcile(.changed)
            XCTAssertEqual(reads.count - before, canPush ? 1 : 0, "canPush=\(canPush)")
        }
    }

    // MARK: The account key

    func testTheAccountKeyIsReadFromTheTokensClaims() throws {
        func token(_ claims: String) -> String {
            let payload = Data(claims.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "e30.\(payload).sig"
        }
        XCTAssertEqual(PushAccountKey.make(accessToken: token(#"{"user_id":7}"#)), "7")
        XCTAssertEqual(PushAccountKey.make(accessToken: token(#"{"user_id":7,"account_incarnation_id":"abc"}"#)), "7/abc")
        XCTAssertEqual(PushAccountKey.make(accessToken: token(#"{"user_id":"u-9"}"#)), "u-9")
        XCTAssertEqual(PushAccountKey.make(accessToken: token(#"{"role":"admin"}"#)), "")
        XCTAssertEqual(PushAccountKey.make(accessToken: "not-a-jwt"), "")
        XCTAssertEqual(PushAccountKey.make(accessToken: "a.b"), "")
        XCTAssertEqual(PushAccountKey.make(accessToken: nil), "")
    }
}

private extension PushRegistrationRead {
    /// The server ids of what was found, for a test that only needs to know which servers have one.
    var servers: [String] {
        if case .found(let all) = self { return all.map(\.serverID) }
        return []
    }
}
