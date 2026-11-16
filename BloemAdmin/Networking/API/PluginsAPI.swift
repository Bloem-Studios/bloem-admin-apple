import Foundation

/// Body of `PUT /api/v2/admin/plugins/installations/{id}`; every field is optional and only `enabled` is sent.
struct SetPluginEnabledRequest: Encodable, Sendable {
    let enabled: Bool
}

extension APIClient {
    private static func pluginPath(_ id: String, _ suffix: String = "") -> String {
        "/api/v2/admin/plugins/installations/\(APIPath.segment(id))\(suffix)"
    }

    /// `GET /api/v2/admin/plugins/installations`: every installed plugin.
    func pluginInstallations() async throws -> [PluginInstallation] {
        try await readAllPages("/api/v2/admin/plugins/installations", pageSize: 200)
    }

    /// `POST .../installations/{id}/restart`: restarts a resident plugin's process.
    func restartPlugin(id: String) async throws {
        try await post(Self.pluginPath(id, "/restart"))
    }

    /// `PUT .../installations/{id}` with `{"enabled": ...}`: turns a plugin on or off.
    func setPluginEnabled(id: String, enabled: Bool) async throws {
        try await put(Self.pluginPath(id), body: SetPluginEnabledRequest(enabled: enabled))
    }

    /// `POST .../installations/{id}/update`: installs the newer version the server has found.
    func applyPluginUpdate(id: String) async throws {
        try await post(Self.pluginPath(id, "/update"))
    }
}
