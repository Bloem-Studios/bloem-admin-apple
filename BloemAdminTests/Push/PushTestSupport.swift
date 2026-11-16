import Foundation
import Security
@testable import BloemAdmin

// Fakes for the push tests. None of them touches the network, the notification center, the keychain or the
// App Group container.

final class InMemoryPushRegistrations: PushRegistrationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: PushRegistration] = [:]
    private var locked = false
    private var saves_ = 0

    init(_ registrations: [PushRegistration] = []) {
        for registration in registrations { items[registration.serverID] = registration }
    }

    var saves: Int { lock.withLock { saves_ } }
    func setLocked(_ value: Bool) { lock.withLock { locked = value } }

    func load() -> PushRegistrationRead {
        lock.withLock { locked ? .locked : .found(items.values.sorted { $0.serverID < $1.serverID }) }
    }

    func save(_ registration: PushRegistration) throws {
        lock.withLock {
            items[registration.serverID] = registration
            saves_ += 1
        }
    }

    func remove(serverID: String) {
        lock.withLock { items[serverID] = nil }
    }
}

extension PushRegistration {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func fixture(
        server: String = "home", name: String = "Silo Home", host: String = "home.example.test",
        device: String = "dev1", token: String = "bad_token-1", account: String = "7",
        apnsToken: String = "apns-1", at: Date = PushRegistration.epoch
    ) -> PushRegistration {
        PushRegistration(
            serverID: server, serverName: name, baseURL: URL(string: "https://\(host)")!, deviceID: device,
            displayToken: token, accountKey: account, tokenHash: PushRegistrar.hash(apnsToken), registeredAt: at
        )
    }
}

final class FakePushSettings: PushSharedSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: PushSharedSettings
    init(showsDetails: Bool = false) { settings = PushSharedSettings(showDetailsOnLockScreen: showsDetails) }
    func load() -> PushSharedSettings { lock.withLock { settings } }
    func save(_ settings: PushSharedSettings) throws { lock.withLock { self.settings = settings } }
}

/// Answers the display-token routes with what it was given, after an optional delay that honours cancellation.
final class FakeDisplayAPI: PushDisplayAPI, @unchecked Sendable {
    struct ContentCall: Equatable { let baseURL: URL; let token: String; let contentID: String }
    struct RetireCall: Equatable { let baseURL: URL; let token: String; let deviceID: String }

    private let lock = NSLock()
    private var contentAnswer_: PushContentResult
    private var retireAnswer_: PushRetireResult
    private let contentDelay: Duration?
    private let retireDelay: Duration?
    private var contentCalls_: [ContentCall] = []
    private var retireCalls_: [RetireCall] = []

    init(
        content: PushContentResult = .failed, retire: PushRetireResult = .retired,
        contentDelay: Duration? = nil, retireDelay: Duration? = nil
    ) {
        contentAnswer_ = content
        retireAnswer_ = retire
        self.contentDelay = contentDelay
        self.retireDelay = retireDelay
    }

    var contentCalls: [ContentCall] { lock.withLock { contentCalls_ } }
    var retireCalls: [RetireCall] { lock.withLock { retireCalls_ } }
    func answerRetire(with result: PushRetireResult) { lock.withLock { retireAnswer_ = result } }

    func content(baseURL: URL, displayToken: String, contentID: String) async -> PushContentResult {
        lock.withLock { contentCalls_.append(ContentCall(baseURL: baseURL, token: displayToken, contentID: contentID)) }
        if let contentDelay { try? await Task.sleep(for: contentDelay) }
        return lock.withLock { contentAnswer_ }
    }

    func retire(baseURL: URL, displayToken: String, deviceID: String) async -> PushRetireResult {
        lock.withLock { retireCalls_.append(RetireCall(baseURL: baseURL, token: displayToken, deviceID: deviceID)) }
        if let retireDelay { try? await Task.sleep(for: retireDelay) }
        return lock.withLock { retireAnswer_ }
    }
}

@MainActor
final class FakePushGateway: PushServerGateway {
    var signedIn: Set<String>
    /// Per server id; a server with no entry answers as a Bloem server that offers push.
    var capabilityAnswers: [String: Result<BloemCapabilities?, Error>] = [:]
    var registerResult: Result<PushRegistered, Error> = .success(PushRegistered(deviceID: "dev1", displayToken: "bad_token-1"))
    var setKindsError: Error?
    var setWidgetsError: Error?
    var accounts: [String: String] = [:]
    private(set) var capabilityCalls: [(serverID: String, fresh: Bool)] = []
    private(set) var registerCalls: [(serverID: String, request: PushRegisterRequest)] = []
    private(set) var kindCalls: [(serverID: String, deviceID: String, kinds: [String: Bool])] = []
    private(set) var widgetCalls: [(serverID: String, deviceID: String, report: WidgetReport)] = []

    static let withPush = BloemCapabilities(featureTokens: ["organization_support_v1", adminPushFeatureToken])
    static let withoutPush = BloemCapabilities(featureTokens: ["organization_support_v1"])

    init(signedIn: Set<String> = ["home"]) { self.signedIn = signedIn }

    func isSignedIn(_ server: AdminServer) -> Bool { signedIn.contains(server.id) }
    func accountKey(_ server: AdminServer) -> String { accounts[server.id] ?? "7" }

    func capabilities(_ server: AdminServer, fresh: Bool) async throws -> BloemCapabilities? {
        capabilityCalls.append((server.id, fresh))
        return try (capabilityAnswers[server.id] ?? .success(Self.withPush)).get()
    }

    func register(_ server: AdminServer, _ request: PushRegisterRequest) async throws -> PushRegistered {
        registerCalls.append((server.id, request))
        return try registerResult.get()
    }

    func setKinds(_ server: AdminServer, deviceID: String, kinds: [String: Bool]) async throws {
        kindCalls.append((server.id, deviceID, kinds))
        if let setKindsError { throw setKindsError }
    }

    func setWidgets(_ server: AdminServer, deviceID: String, report: WidgetReport) async throws -> WidgetReport {
        widgetCalls.append((server.id, deviceID, report))
        if let setWidgetsError { throw setWidgetsError }
        return report
    }
}

/// What the person has placed; mutable, so a test can add and remove a widget between passes.
final class FakeWidgetPlacements: WidgetPlacementReading, @unchecked Sendable {
    private let lock = NSLock()
    private var kinds_: Set<String>?
    init(_ kinds: Set<String>? = []) { kinds_ = kinds }
    var kinds: Set<String>? { get { lock.withLock { kinds_ } } set { lock.withLock { kinds_ = newValue } } }
    func placedKinds() async -> Set<String>? { kinds }
}

final class FakeKindReloader: WidgetKindReloading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls_: [[SiloWidgetKind]] = []
    var calls: [[SiloWidgetKind]] { lock.withLock { calls_ } }
    func reload(kinds: [SiloWidgetKind]) { lock.withLock { calls_.append(kinds) } }
}

final class PushCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count_ = 0
    var count: Int { lock.withLock { count_ } }
    func bump() { lock.withLock { count_ += 1 } }
}

final class FakePushNotifier: PushLocalNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var posted_: [PushLocalNote] = []
    private var removed_: [String] = []
    var posted: [PushLocalNote] { lock.withLock { posted_ } }
    var removed: [String] { lock.withLock { removed_ } }

    func post(_ note: PushLocalNote) async { lock.withLock { posted_.append(note) } }
    func removeDelivered(identifiers: [String]) async { lock.withLock { removed_.append(contentsOf: identifiers) } }
}

final class FakeDecider: PushRequestDeciding, @unchecked Sendable {
    struct Call: Equatable { let serverID: String; let requestID: String; let approve: Bool }
    private let lock = NSLock()
    private let outcome: PushDecisionOutcome
    private let delay: Duration?
    private var calls_: [Call] = []
    var calls: [Call] { lock.withLock { calls_ } }

    init(_ outcome: PushDecisionOutcome, delay: Duration? = nil) {
        self.outcome = outcome
        self.delay = delay
    }

    func decide(serverID: String, requestID: String, approve: Bool) async -> PushDecisionOutcome {
        lock.withLock { calls_.append(Call(serverID: serverID, requestID: requestID, approve: approve)) }
        if let delay { try? await Task.sleep(for: delay) }
        return outcome
    }
}

/// A keychain in memory that understands the three queries the registration store makes: one item by account,
/// every item of the service, and the add that follows a miss.
final class FakePushKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private(set) var queries: [[String: Any]] = []
    var readStatus: OSStatus = errSecSuccess

    var stored: [String: Data] { lock.withLock { items } }
    func put(_ data: Data, account: String) { lock.withLock { items[account] = data } }

    var client: SecurityClient {
        SecurityClient(
            copyMatching: { [self] query, result in
                lock.withLock {
                    let q = query as! [String: Any]
                    queries.append(q)
                    if readStatus != errSecSuccess { return readStatus }
                    if let account = q[kSecAttrAccount as String] as? String {
                        guard let data = items[account] else { return errSecItemNotFound }
                        result?.pointee = data as CFData
                        return errSecSuccess
                    }
                    guard !items.isEmpty else { return errSecItemNotFound }
                    result?.pointee = items.keys.sorted().compactMap { items[$0] } as CFArray
                    return errSecSuccess
                }
            },
            update: { [self] query, attributes in
                lock.withLock {
                    let q = query as! [String: Any]
                    queries.append(q)
                    let account = q[kSecAttrAccount as String] as! String
                    guard items[account] != nil else { return errSecItemNotFound }
                    queries.append(attributes as! [String: Any])
                    items[account] = (attributes as! [String: Any])[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            add: { [self] query, _ in
                lock.withLock {
                    let q = query as! [String: Any]
                    queries.append(q)
                    items[q[kSecAttrAccount as String] as! String] = q[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            delete: { [self] query in
                lock.withLock {
                    let q = query as! [String: Any]
                    queries.append(q)
                    items[q[kSecAttrAccount as String] as! String] = nil
                    return errSecSuccess
                }
            }
        )
    }
}

enum PushSamples {
    /// What the server answers for one request waiting.
    static let requestJSON = """
    {"delivery_id":"abc-1","kind":"admin.request_waiting","channel":"requests","title":"Sam requested Dune",
     "body":"3 waiting","lock_screen":"New request waiting","page":"requests","item_id":"req-9",
     "subject_type":"request","actions":["approve","decline"],"badge":3,"created_at":"2026-11-15T12:00:00Z"}
    """

    static func content(_ json: String = requestJSON) -> PushContent {
        try! JSONDecoder().decode(PushContent.self, from: Data(json.utf8))
    }

    static let scanJSON = """
    {"delivery_id":"abc-2","kind":"admin.scan_failed","channel":"libraries","title":"Scan failed: Movies",
     "body":"The mount is empty","lock_screen":"A library scan failed","page":"libraries","item_id":"lib-4",
     "subject_type":"library","actions":[],"created_at":"2026-11-15T12:00:00Z"}
    """

    static let wire = PushWire(raw: "dev1.abc-1")!
}
