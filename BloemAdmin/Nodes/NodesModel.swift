import Foundation

extension SectionModel where Payload == [NodeSummary] {
    /// The Nodes page of one server (`serverName` set in All servers mode).
    static func nodes(serverName: String? = nil) -> SectionModel<[NodeSummary]> {
        SectionModel<[NodeSummary]>(serverName: serverName, loadFallback: String(localized: "Could not load nodes.")) { client in
            try await client.nodeSummaries()
        }
    }

    @discardableResult
    func drain(id: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        await act(id: id, fallback: String(localized: "Could not drain this node."), client: client, sessionState: sessionState) {
            try await $0.drainNode(id: id)
        }
    }

    @discardableResult
    func resume(id: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        await act(id: id, fallback: String(localized: "Could not resume this node."), client: client, sessionState: sessionState) {
            try await $0.resumeNode(id: id)
        }
    }

    @discardableResult
    func checkNow(id: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        await act(id: id, fallback: String(localized: "Could not check this node."), client: client, sessionState: sessionState) {
            try await $0.checkNode(id: id)
        }
    }

    /// Enable or disable a node. The write is guarded by the node's configuration version, read just
    /// before; a node without one is left alone.
    @discardableResult
    func setEnabled(_ enabled: Bool, id: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        await act(
            id: id,
            fallback: enabled ? String(localized: "Could not enable this node.") : String(localized: "Could not disable this node."),
            conflictMessage: String(localized: "This node was changed somewhere else. Reload the page and try again."),
            client: client, sessionState: sessionState
        ) { client in
            let versions = try await client.nodeConfigurationVersions()
            guard let validator = versions.first(where: { $0.id == id })?.configEtag, !validator.isEmpty else {
                throw SectionActionError(
                    message: String(localized: "This node has no saved configuration version, so it cannot be changed from here. Change it on the web.")
                )
            }
            try await client.setNodeEnabled(id: id, enabled: enabled, validator: validator)
        }
    }
}
