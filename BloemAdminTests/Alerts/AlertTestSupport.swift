import Foundation
@testable import BloemAdmin

// Fakes for the alert tests. None of them touches the network, the notification center, the background
// task scheduler or the App Group container.

/// A clock the test moves by hand.
final class AlertTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.date = date }

    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    var reader: @Sendable () -> Date { { [self] in now } }
}

final class FakeBackgroundScheduler: BackgroundTaskSubmitting, @unchecked Sendable {
    enum Call: Equatable {
        case submit(String, Date)
        case cancel(String)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] { lock.withLock { recorded } }
    var last: Call? { calls.last }

    func submit(identifier: String, earliestBeginDate: Date) throws {
        lock.withLock { recorded.append(.submit(identifier, earliestBeginDate)) }
    }

    func cancel(identifier: String) {
        lock.withLock { recorded.append(.cancel(identifier)) }
    }
}

final class FakeNotifier: AlertNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var posted_: [AlertNotificationContent] = []
    private var removed_: [String] = []

    var posted: [AlertNotificationContent] { lock.withLock { posted_ } }
    var removed: [String] { lock.withLock { removed_ } }

    func post(_ content: AlertNotificationContent) async {
        lock.withLock { posted_.append(content) }
    }

    func removeDelivered(identifiers: [String]) async {
        lock.withLock { removed_.append(contentsOf: identifiers) }
    }
}

final class FakeAuthorizer: NotificationAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var current: NotificationPermission
    private let answer: Bool
    private var requests_ = 0
    private var statusReads_ = 0

    /// `answer` is what the person taps when asked.
    init(_ status: NotificationPermission, answer: Bool = true) {
        current = status
        self.answer = answer
    }

    var requests: Int { lock.withLock { requests_ } }
    var statusReads: Int { lock.withLock { statusReads_ } }

    func status() async -> NotificationPermission {
        lock.withLock { statusReads_ += 1; return current }
    }

    func requestPermission() async -> Bool {
        lock.withLock {
            requests_ += 1
            current = answer ? .allowed : .denied
            return answer
        }
    }
}

/// Answers per server address; an address with no answer set is up.
final class FakeProbe: HealthChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: HealthProbeResult] = [:]
    private var asked_: [URL] = []

    var asked: [URL] { lock.withLock { asked_ } }

    func set(_ result: HealthProbeResult, for url: URL) {
        lock.withLock { results[url.absoluteString] = result }
    }

    func check(baseURL: URL) async -> HealthProbeResult {
        lock.withLock {
            asked_.append(baseURL)
            return results[baseURL.absoluteString] ?? .up
        }
    }
}

final class InMemorySnapshotStore: SnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: AdminSnapshot?
    private var saves_ = 0

    init(_ snapshot: AdminSnapshot? = nil) { self.snapshot = snapshot }

    var saves: Int { lock.withLock { saves_ } }

    func load() -> AdminSnapshot? { lock.withLock { snapshot } }

    func save(_ snapshot: AdminSnapshot) throws {
        lock.withLock { self.snapshot = snapshot; saves_ += 1 }
    }
}

final class FakeReloader: WidgetTimelineReloading, @unchecked Sendable {
    private let lock = NSLock()
    private var count_ = 0
    var count: Int { lock.withLock { count_ } }
    func reloadAll() { lock.withLock { count_ += 1 } }
}

enum AlertTestDefaults {
    /// A throwaway defaults domain; remove it with `defaults.removePersistentDomain(forName:)`.
    static func make() -> (UserDefaults, String) {
        let suite = "AlertTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("no defaults suite") }
        return (defaults, suite)
    }
}

extension AdminServer {
    static func fixture(_ id: String, name: String? = nil, host: String? = nil) -> AdminServer {
        AdminServer(
            id: id,
            baseURL: URL(string: "https://\(host ?? "\(id).example.test")")!,
            displayName: name ?? "Server \(id)"
        )
    }
}
