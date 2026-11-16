import Foundation

/// The configuration version of a node: `config_etag` of `GET /api/v2/admin/nodes`, which guards a write
/// to the node (`PUT /api/v2/admin/nodes/{id}` answers 428 without it). Absent for a node with no saved
/// configuration.
struct NodeConfigurationVersion: Decodable, Sendable {
    let id: String
    let configEtag: String?

    enum CodingKeys: String, CodingKey {
        case id
        case configEtag = "config_etag"
    }
}

/// Body of `PUT /api/v2/admin/nodes/{id}`; every field is optional and only `enabled` is sent.
struct SetNodeEnabledRequest: Encodable, Sendable {
    let enabled: Bool
}

extension APIClient {
    private static func nodePath(_ id: String, _ suffix: String = "") -> String {
        "/api/v2/admin/nodes/\(APIPath.segment(id))\(suffix)"
    }

    /// `GET /api/v2/admin/nodes/summary`: every node with its health, drain state, load and capacity.
    func nodeSummaries() async throws -> [NodeSummary] {
        try await readAllPages("/api/v2/admin/nodes/summary", pageSize: 200)
    }

    /// `GET /api/v2/admin/nodes`, read only for the configuration versions that guard a node write.
    func nodeConfigurationVersions() async throws -> [NodeConfigurationVersion] {
        try await readAllPages("/api/v2/admin/nodes", pageSize: 200)
    }

    /// `POST /api/v2/admin/nodes/{id}/drain`: new work stops being placed on the node.
    func drainNode(id: String) async throws {
        try await post(Self.nodePath(id, "/drain"))
    }

    /// `POST /api/v2/admin/nodes/{id}/resume`.
    func resumeNode(id: String) async throws {
        try await post(Self.nodePath(id, "/resume"))
    }

    /// `POST /api/v2/admin/nodes/{id}/check`: probes the node now.
    func checkNode(id: String) async throws {
        try await post(Self.nodePath(id, "/check"))
    }

    /// `PUT /api/v2/admin/nodes/{id}` with `If-Match`; never replayed.
    func setNodeEnabled(id: String, enabled: Bool, validator: String) async throws {
        try await putConditional(Self.nodePath(id), body: SetNodeEnabledRequest(enabled: enabled), validator: validator)
    }
}
