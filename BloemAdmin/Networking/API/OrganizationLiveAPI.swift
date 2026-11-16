import Foundation

/// The organization live socket (docs/design.md): a Bloem server tells an organization
/// administrator's app what changed, and the page reads the REST route again. It is not Silo's events socket: it is
/// opened with a ticket minted by the organization context pass, and the socket is bound to the organization that
/// pass names.
enum OrganizationLiveProtocol {
    static let name = "bloem-live.v1"
    /// The public feature token a server advertises when it has the socket. Without it the pages keep what they did.
    static let featureToken = "organization_live_v1"
}

/// `POST /api/bloem/v2/admin/organization/live/ticket` (context pass, no body): a single-use credential, valid 30
/// seconds. `channels` is what the server serves; `org.streams` is missing when it cannot list live sessions.
struct OrganizationLiveTicket: Decodable, Sendable, Equatable {
    let ticket: String
    let protocolName: String
    let channels: [String]
    let maxConnectionSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case ticket
        case protocolName = "protocol"
        case channels
        case maxConnectionSeconds = "max_connection_seconds"
    }

    init(ticket: String, protocolName: String = OrganizationLiveProtocol.name, channels: [String], maxConnectionSeconds: Int? = nil) {
        self.ticket = ticket
        self.protocolName = protocolName
        self.channels = channels
        self.maxConnectionSeconds = maxConnectionSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticket = try c.decode(String.self, forKey: .ticket)
        protocolName = try c.decode(String.self, forKey: .protocolName)
        channels = (try? c.decode([String].self, forKey: .channels)) ?? []
        maxConnectionSeconds = try? c.decode(Int.self, forKey: .maxConnectionSeconds)
    }
}

extension APIClient {
    /// Pass client. A 401 is the session's to renew (`OrganizationSession.read`).
    func createOrganizationLiveTicket() async throws -> OrganizationLiveTicket {
        try await postForResult("/api/bloem/v2/admin/organization/live/ticket")
    }

    /// `wss://<server><base path>/api/bloem/v2/organization/live/ws`, or nil for a server address that is not HTTPS.
    /// The route sits outside `/admin` because a WebSocket client cannot send a header: the ticket rides in the
    /// subprotocol, never in the URL.
    nonisolated var organizationLiveSocketURL: URL? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https" else { return nil }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.scheme = "wss"
        components.percentEncodedPath = basePath + "/api/bloem/v2/organization/live/ws"
        components.query = nil
        return components.url
    }
}

extension BloemCapabilities {
    /// This server has the organization live socket.
    var offersOrganizationLive: Bool { featureTokens.contains(OrganizationLiveProtocol.featureToken) }
}
