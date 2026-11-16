import Foundation
import Observation

/// The Network access page's state: each installed overlay provider and the hosts that run it. Connect
/// and Disconnect act on one host and answer the state it reached; enrolment may continue afterwards,
/// so the page offers a refresh.
@Observable
@MainActor
final class NetworkAccessModel {
    struct Entry: Identifiable, Equatable {
        let provider: NetworkAccessProvider
        var hosts: [NetworkAccessHost]
        /// Why this provider's status could not be read.
        var error: String?

        var id: String { provider.id }
    }

    let serverName: String?
    private(set) var entries: [Entry] = []
    private(set) var hasLoaded = false
    private(set) var loadFailure: ServerSectionFailure?
    private(set) var busyHostIDs: Set<String> = []
    private(set) var actionError: String?
    private var requestID = 0

    init(serverName: String? = nil) {
        self.serverName = serverName
    }

    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        requestID += 1
        let token = requestID
        do {
            let providers = try await client.networkAccessProviders()
            var loaded: [Entry] = []
            for provider in providers {
                do {
                    loaded.append(Entry(provider: provider, hosts: try await client.networkAccessHosts(provider: provider.provider), error: nil))
                } catch {
                    loaded.append(Entry(
                        provider: provider, hosts: [],
                        error: ErrorMessage.text(
                            for: error, sessionState: sessionState,
                            fallback: String(localized: "Could not read this provider's status. Pull down to try again"), serverName: serverName
                        )
                    ))
                }
            }
            guard token == requestID else { return }
            entries = loaded
            loadFailure = nil
            hasLoaded = true
        } catch {
            guard token == requestID else { return }
            if !hasLoaded {
                loadFailure = ErrorMessage.failure(
                    for: error, sessionState: sessionState,
                    fallback: String(localized: "Could not read the network access providers. Check your connection and try again"), serverName: serverName
                )
            }
        }
    }

    func connect(provider: NetworkAccessProvider, host: NetworkAccessHost, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        await act(provider: provider, host: host, sessionState: sessionState) {
            try await client.connectNetworkAccess(provider: provider.provider, hostIDs: [host.id])
        }
    }

    func disconnect(provider: NetworkAccessProvider, host: NetworkAccessHost, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        await act(provider: provider, host: host, sessionState: sessionState) {
            try await client.disconnectNetworkAccess(provider: provider.provider, hostIDs: [host.id])
        }
    }

    private func act(
        provider: NetworkAccessProvider, host: NetworkAccessHost, sessionState: ServerScopedSession?,
        _ operation: () async throws -> [NetworkAccessHost]
    ) async {
        guard !busyHostIDs.contains(host.id) else { return }
        busyHostIDs.insert(host.id)
        actionError = nil
        defer { busyHostIDs.remove(host.id) }
        do {
            let answered = try await operation()
            guard let index = entries.firstIndex(where: { $0.provider.id == provider.id }) else { return }
            // Hosts not named answer their current status, so the answer replaces the whole list.
            if !answered.isEmpty { entries[index].hosts = answered }
        } catch {
            actionError = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "Could not change the connection. Check your connection and try again"),
                serverName: serverName
            )
        }
    }
}

extension NetworkAccessHost {
    /// The web's wording for the host's state.
    var stateLabel: String {
        switch state {
        case "connected": String(localized: "Connected")
        case "connecting": String(localized: "Connecting")
        case "awaiting_authorization": String(localized: "Waiting for authorization")
        case "disconnected": String(localized: "Disconnected")
        case "unavailable": String(localized: "Plugin not running")
        default: String(localized: "Error")
        }
    }

    var isOn: Bool { state == "connected" || state == "connecting" || state == "awaiting_authorization" }

    /// "API server", or the node's name; the web's `host.apiServer` and `host.proxyNode`.
    var title: String {
        if role == "api" || id == "api" {
            return name.isEmpty ? String(localized: "API server") : String(localized: "API server · \(name)")
        }
        return name.isEmpty ? String(localized: "Proxy node") : String(localized: "Proxy node · \(name)")
    }

    /// The enrolment page the plugin reported, only when it is a web address.
    var authorizationURL: URL? {
        guard let authURL, let url = URL(string: authURL), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }
}
