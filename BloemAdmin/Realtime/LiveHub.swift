import Foundation
import Network
import Observation

/// Tells the hub when the network path changes in a way worth reconnecting for.
protocol NetworkPathSource: AnyObject, Sendable {
    /// `onChange` is called when the device gets a usable path that differs from the one before (another
    /// interface, or the network back after none). The path at `start` is not a change.
    func start(onChange: @escaping @Sendable () -> Void)
    func stop()
}

final class SystemNetworkPathSource: NetworkPathSource, @unchecked Sendable {
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var lastSignature: String?

    func start(onChange: @escaping @Sendable () -> Void) {
        let monitor = NWPathMonitor()
        lock.withLock {
            self.monitor?.cancel()
            self.monitor = monitor
            lastSignature = nil
        }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let interfaces = path.availableInterfaces.map { "\($0.type)" }.sorted().joined(separator: ",")
            let signature = "\(path.status)|\(interfaces)"
            let changed: Bool = lock.withLock {
                defer { lastSignature = signature }
                guard let previous = lastSignature else { return false }
                return previous != signature
            }
            if changed, path.status == .satisfied { onChange() }
        }
        monitor.start(queue: DispatchQueue(label: "bloem.live.path"))
    }

    func stop() {
        lock.withLock {
            monitor?.cancel()
            monitor = nil
            lastSignature = nil
        }
    }
}

/// The app's live connections, one per server, and the app's foreground state. A scene reports its phase
/// here; every connection follows it. The network monitor only runs while some scene is active.
@MainActor
final class LiveHub {
    static let shared = LiveHub()

    private var connections: [String: LiveConnection] = [:]
    private var activeScenes: Set<AppSceneID> = []
    private let pathSource: any NetworkPathSource
    private(set) var foreground = false
    /// How a connection is made for a client; replaced in tests and UI-test fixtures.
    var makeConnection: (APIClient) -> LiveConnection = { LiveConnection(client: $0) }

    init(pathSource: any NetworkPathSource = SystemNetworkPathSource()) {
        self.pathSource = pathSource
    }

    /// The connection to `client`'s server, made on first use. A later client for the same server (a
    /// refreshed sign-in) replaces the one the connection uses for its next ticket.
    func connection(for client: APIClient) -> LiveConnection {
        let key = client.origin.absoluteString
        if let existing = connections[key] {
            existing.endpoint = LiveEndpoint.events(client: client)
            return existing
        }
        let created = makeConnection(client)
        created.setForeground(foreground)
        connections[key] = created
        return created
    }

    /// The organization's live connection, shared by the pages of that organization on that server and made on first
    /// use. It is not the account's connection: it is opened with the organization pass, and carries the `org.*` channels.
    /// A later session for the same organization (the pass was opened again) replaces the one the connection uses.
    func organizationConnection(for session: OrganizationSession) -> LiveConnection {
        let key = "\(session.baseURL.absoluteString)#organization:\(session.organizationID)"
        if let existing = connections[key] {
            existing.endpoint = LiveEndpoint.organization(session: session)
            return existing
        }
        let created = LiveConnection(endpoint: .organization(session: session))
        created.setForeground(foreground)
        connections[key] = created
        return created
    }

    /// A scene's phase. `.inactive` changes nothing (a notification pull-down is not leaving the app).
    func sceneChanged(_ id: AppSceneID, phase: AppScenePhase) {
        switch phase {
        case .active: activeScenes.insert(id)
        case .background: activeScenes.remove(id)
        case .inactive: return
        }
        setForeground(!activeScenes.isEmpty)
    }

    func setForeground(_ value: Bool) {
        guard value != foreground else { return }
        foreground = value
        if value {
            pathSource.start { [weak self] in
                Task { @MainActor in self?.networkPathChanged() }
            }
        } else {
            pathSource.stop()
        }
        for connection in connections.values { connection.setForeground(value) }
    }

    func networkPathChanged() {
        for connection in connections.values { connection.networkPathChanged() }
    }

    /// Drops connections for servers that are gone.
    func retain(origins: Set<String>) {
        for (key, connection) in connections where !origins.contains(key) && connection.subscriberCount == 0 {
            connection.setForeground(false)
            connections[key] = nil
        }
    }

    var connectionCount: Int { connections.count }
}
