import Foundation
import Observation

/// Told when a sign-in starts or ends, so the phone's push registrations follow it: registered on sign-in,
/// stopped on sign-out and when a server is removed.
@MainActor
protocol PushLifecycle: AnyObject {
    func serverSignedIn(_ server: AdminServer)
    func serverSignedOut(_ server: AdminServer)
}

protocol ServerMetadataStoring: Sendable {
    func loadServers() throws -> [AdminServer]
    func saveServers(_ servers: [AdminServer]) throws
}

final class UserDefaultsServerMetadataStore: ServerMetadataStoring, Sendable {
    private static let defaultsKey = "bloem.admin.servers"
    // UserDefaults is thread-safe, but Foundation does not declare it
    // Sendable. ServerStore calls this boundary from the main actor.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func loadServers() throws -> [AdminServer] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return try JSONDecoder().decode([AdminServer].self, from: data)
    }

    func saveServers(_ servers: [AdminServer]) throws {
        defaults.set(try JSONEncoder().encode(servers), forKey: Self.defaultsKey)
    }
}

@Observable
@MainActor
final class ServerStore {
    private(set) var servers: [AdminServer]
    private(set) var initializationError: Error?
    /// Bumped whenever a stored sign-in is added, replaced or removed. Keychain reads are not observable, so
    /// a view that shows whether a server is signed in reads this first and re-reads the Keychain on change.
    private(set) var credentialRevision = 0
    /// Weak: the lifecycle (`PushRuntime`) outlives any store.
    @ObservationIgnored weak var pushLifecycle: (any PushLifecycle)?

    private let metadataStore: any ServerMetadataStoring
    nonisolated private let credentialStore: any CredentialStoring
    /// Where the widgets read the sign-in (see `WidgetCredentialMirror`). Off unless the app turns it on.
    nonisolated private let mirror: WidgetCredentialMirror
    /// Whether each saved server is a Bloem server, asked once per server for the life of the store (the session) and
    /// shared by every client this store builds. Every `/api/bloem/` call and menu entry goes through it.
    nonisolated let bloemDetector = BloemServerDetector()

    init(
        metadataStore: any ServerMetadataStoring = UserDefaultsServerMetadataStore(defaults: .standard),
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        mirror: WidgetCredentialMirror = .disabled
    ) {
        self.metadataStore = metadataStore
        self.credentialStore = credentialStore
        self.mirror = mirror
        do {
            servers = try metadataStore.loadServers()
            initializationError = nil
        } catch {
            servers = []
            initializationError = error
        }
    }

    func addServer(_ server: AdminServer, credentials: ServerCredentials) throws {
        let previousCredentials = try credentialStore.credentials(for: server.id)
        try credentialStore.save(credentials, for: server.id)
        let candidate = servers + [server]
        do {
            try metadataStore.saveServers(candidate)
            servers = candidate
            credentialRevision += 1
            mirror.publish(credentials, serverID: server.id)
        } catch {
            try restore(previousCredentials, for: server.id)
            throw error
        }
        pushLifecycle?.serverSignedIn(server)
    }

    func addServer(_ server: AdminServer, accessToken: String, refreshToken: String? = nil) throws {
        try addServer(
            server,
            credentials: ServerCredentials(
                version: ServerCredentials.currentVersion,
                accessToken: accessToken,
                refreshToken: refreshToken
            )
        )
    }

    func updateCredentials(_ credentials: ServerCredentials, forServerID id: String) throws {
        try credentialStore.save(credentials, for: id)
        credentialRevision += 1
        mirror.publish(credentials, serverID: id)
    }

    func updateToken(_ accessToken: String, refreshToken: String? = nil, forServerID id: String) throws {
        let current = try credentialStore.credentials(for: id)
        try updateCredentials(
            ServerCredentials(
                version: ServerCredentials.currentVersion,
                accessToken: accessToken,
                refreshToken: refreshToken ?? current?.refreshToken
            ),
            forServerID: id
        )
    }

    func removeServer(_ id: String, sessionState: AdminSessionState? = nil) throws {
        let previousCredentials = try credentialStore.credentials(for: id)
        let removed = servers.first { $0.id == id }
        try credentialStore.deleteCredentials(for: id)
        let candidate = servers.filter { $0.id != id }
        do {
            try metadataStore.saveServers(candidate)
            servers = candidate
            if let removed { bloemDetector.forget(origin: removed.baseURL) }
        } catch {
            try restore(previousCredentials, for: id)
            throw error
        }
        credentialRevision += 1
        mirror.remove(serverID: id)
        sessionState?.clearSession(serverID: id)
        if let removed { pushLifecycle?.serverSignedOut(removed) }
    }

    func renameServer(_ id: String, to displayName: String) throws {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        var candidate = servers
        candidate[index].displayName = displayName
        try metadataStore.saveServers(candidate)
        servers = candidate
    }

    /// Remembers the provider a server was last signed in with, or clears it with nil (password sign-in).
    func setSignInProvider(_ providerID: String?, forServerID id: String) throws {
        guard let index = servers.firstIndex(where: { $0.id == id }),
              servers[index].signInProviderID != providerID else { return }
        var candidate = servers
        candidate[index].signInProviderID = providerID
        try metadataStore.saveServers(candidate)
        servers = candidate
    }

    func signOut(_ id: String, sessionState: AdminSessionState? = nil) throws {
        let ended = servers.first { $0.id == id }
        try credentialStore.deleteCredentials(for: id)
        credentialRevision += 1
        mirror.remove(serverID: id)
        sessionState?.clearSession(serverID: id)
        if let ended { pushLifecycle?.serverSignedOut(ended) }
    }

    /// The person just signed in again to a saved server (its sign-in expired and they entered it). A silent
    /// refresh is not one. Push registers again for this account.
    func noteInteractiveSignIn(serverID id: String) {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        pushLifecycle?.serverSignedIn(server)
    }

    // MARK: Widgets

    /// Takes tokens the widget rotated back into the app's store, so the app never spends a refresh token a
    /// widget already used. True when it took some.
    @discardableResult
    func adoptWidgetRotation(for id: String) -> Bool {
        guard servers.contains(where: { $0.id == id }), let rotated = mirror.rotatedByWidget(serverID: id) else { return false }
        do {
            try updateCredentials(rotated, forServerID: id)
            return true
        } catch {
            return false
        }
    }

    /// Brings the mirror in line with the store: adopts what a widget rotated, publishes the rest. Runs when
    /// the app comes to the foreground.
    func syncWidgetCredentials() {
        guard mirror.isEnabled else { return }
        for server in servers {
            if adoptWidgetRotation(for: server.id) { continue }
            if let credentials = try? credentialStore.credentials(for: server.id) {
                mirror.publish(credentials, serverID: server.id)
            }
        }
    }

    nonisolated func credentials(for serverID: String) throws -> ServerCredentials? {
        try credentialStore.credentials(for: serverID)
    }

    nonisolated func accessToken(for serverID: String) -> String? {
        try? credentials(for: serverID)?.accessToken
    }

    nonisolated func refreshToken(for serverID: String) -> String? {
        try? credentials(for: serverID)?.refreshToken
    }

    nonisolated func client(for server: AdminServer, session: URLSession? = nil) -> APIClient {
        APIClient(baseURL: server.baseURL, accessToken: accessToken(for: server.id), session: session, bloemDetector: bloemDetector)
    }

    func seedAdministratorCredentialIfAbsent(in sessionState: AdminSessionState, serverID: String) {
        guard let accessToken = accessToken(for: serverID) else { return }
        sessionState.seedAdministratorTokenIfAbsent(accessToken, serverID: serverID)
    }

    func client(
        for server: AdminServer,
        sessionState: AdminSessionState,
        session: URLSession? = nil
    ) -> APIClient {
        seedAdministratorCredentialIfAbsent(in: sessionState, serverID: server.id)
        return APIClient(
            baseURL: server.baseURL,
            credentialProvider: sessionState.credentialProvider(serverID: server.id),
            session: session,
            bloemDetector: bloemDetector
        )
    }

    func authenticatedClients(
        for servers: [AdminServer],
        sessionState: AdminSessionState,
        session: URLSession? = nil
    ) -> [String: APIClient] {
        var clients: [String: APIClient] = [:]
        for server in servers {
            clients[server.id] = client(for: server, sessionState: sessionState, session: session)
        }
        return clients
    }

    private func restore(_ credentials: ServerCredentials?, for serverID: String) throws {
        if let credentials {
            try credentialStore.save(credentials, for: serverID)
        } else {
            try credentialStore.deleteCredentials(for: serverID)
        }
    }
}
