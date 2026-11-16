import Foundation

extension SectionModel where Payload == [PluginInstallation] {
    /// The Plugins page of one server (`serverName` set in All servers mode).
    static func plugins(serverName: String? = nil) -> SectionModel<[PluginInstallation]> {
        SectionModel<[PluginInstallation]>(serverName: serverName, loadFallback: String(localized: "Could not load plugins.")) { client in
            try await client.pluginInstallations()
        }
    }

    @discardableResult
    func restart(id: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        await act(id: id, fallback: String(localized: "Could not restart this plugin."), client: client, sessionState: sessionState) {
            try await $0.restartPlugin(id: id)
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, id: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        await act(
            id: id,
            fallback: enabled ? String(localized: "Could not turn this plugin on.") : String(localized: "Could not turn this plugin off."),
            client: client, sessionState: sessionState
        ) {
            try await $0.setPluginEnabled(id: id, enabled: enabled)
        }
    }

    @discardableResult
    func applyUpdate(id: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        await act(id: id, fallback: String(localized: "Could not update this plugin."), client: client, sessionState: sessionState) {
            try await $0.applyPluginUpdate(id: id)
        }
    }
}
