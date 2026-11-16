import Foundation

/// An installed network access provider (Tailscale, NetBird): an overlay network that reaches the
/// server without port forwarding. Read from `GET /api/v2/network-access/capabilities`.
struct NetworkAccessProvider: Decodable, Equatable, Identifiable, Sendable {
    /// The slug the admin routes use.
    let provider: String
    let displayName: String

    var id: String { provider }

    enum CodingKeys: String, CodingKey {
        case provider
        case displayName = "display_name"
    }

    init(provider: String, displayName: String) {
        self.provider = provider
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName).flatMap { $0.isEmpty ? nil : $0 } ?? provider
    }
}

private struct NetworkAccessProviderList: Decodable {
    let providers: [NetworkAccessProvider]
}

/// One process running the provider (the API server or a proxy node) and where it stands.
struct NetworkAccessHost: Decodable, Equatable, Identifiable, Sendable {
    /// `api` for the API server, `node:<id>` for a proxy node.
    let id: String
    let role: String
    let name: String
    /// `disconnected`, `awaiting_authorization`, `connecting`, `connected`, `error` or `unavailable`.
    let state: String
    let hostname: String?
    let origin: String?
    let authURL: String?
    let error: String?
    let updatedAt: Date?

    private struct Ref: Decodable {
        let id: String
        let role: String?
        let name: String?
    }

    private enum CodingKeys: String, CodingKey {
        case host, state, hostname, origin, error
        case authURL = "auth_url"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ref = try c.decode(Ref.self, forKey: .host)
        id = ref.id
        role = ref.role ?? ""
        name = ref.name ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "error"
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        authURL = try c.decodeIfPresent(String.self, forKey: .authURL)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    init(
        id: String, role: String = "api", name: String = "", state: String, hostname: String? = nil,
        origin: String? = nil, authURL: String? = nil, error: String? = nil, updatedAt: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.name = name
        self.state = state
        self.hostname = hostname
        self.origin = origin
        self.authURL = authURL
        self.error = error
        self.updatedAt = updatedAt
    }
}

private struct NetworkAccessStatusWire: Decodable {
    let hosts: [NetworkAccessHost]
}

private struct NetworkAccessCommandBody: Encodable {
    let hosts: [String]
}

extension APIClient {
    /// `GET /api/v2/network-access/capabilities`: the installed providers.
    func networkAccessProviders() async throws -> [NetworkAccessProvider] {
        let list: NetworkAccessProviderList = try await get("/api/v2/network-access/capabilities")
        return list.providers
    }

    /// `GET /api/v2/admin/network-access/{provider}/status`: the provider's live state on every host.
    func networkAccessHosts(provider: String) async throws -> [NetworkAccessHost] {
        let wire: NetworkAccessStatusWire = try await get("/api/v2/admin/network-access/\(APIPath.segment(provider))/status")
        return wire.hosts
    }

    /// `POST /api/v2/admin/network-access/{provider}/connect` for the named hosts. Answers 202 with the
    /// state each host reached; enrollment may continue after it.
    func connectNetworkAccess(provider: String, hostIDs: [String]) async throws -> [NetworkAccessHost] {
        let wire: NetworkAccessStatusWire = try await post(
            "/api/v2/admin/network-access/\(APIPath.segment(provider))/connect", body: NetworkAccessCommandBody(hosts: hostIDs)
        )
        return wire.hosts
    }

    /// `POST /api/v2/admin/network-access/{provider}/disconnect` for the named hosts.
    func disconnectNetworkAccess(provider: String, hostIDs: [String]) async throws -> [NetworkAccessHost] {
        let wire: NetworkAccessStatusWire = try await post(
            "/api/v2/admin/network-access/\(APIPath.segment(provider))/disconnect", body: NetworkAccessCommandBody(hosts: hostIDs)
        )
        return wire.hosts
    }
}
