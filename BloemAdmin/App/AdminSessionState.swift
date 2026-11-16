import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class AdminSessionState {
    private var administratorTokenByServer: [String: String] = [:]
    private var tokenExpiredServerIDs: Set<String> = []
    private var generationByServer: [String: UInt64] = [:]
    @ObservationIgnored private var refreshFlightByServer: [String: (id: UUID, task: Task<RefreshedTokens?, Never>)] = [:]

    func isTokenExpired(for serverID: String) -> Bool {
        tokenExpiredServerIDs.contains(serverID)
    }

    func generation(for serverID: String) -> UInt64 {
        generationByServer[serverID] ?? 0
    }

    func setAdministratorToken(_ token: String, serverID: String) {
        advanceGeneration(for: serverID)
        administratorTokenByServer[serverID] = token
        tokenExpiredServerIDs.remove(serverID)
    }

    func seedAdministratorTokenIfAbsent(_ token: String, serverID: String) {
        guard administratorTokenByServer[serverID] == nil else { return }
        setAdministratorToken(token, serverID: serverID)
    }

    func performSingleFlightRefresh(
        serverID: String,
        operation: @escaping @MainActor () async -> RefreshedTokens?
    ) async -> RefreshedTokens? {
        if let existing = refreshFlightByServer[serverID] {
            return await existing.task.value
        }

        let id = UUID()
        let task = Task { @MainActor in
            await operation()
        }
        refreshFlightByServer[serverID] = (id, task)
        let result = await task.value
        if refreshFlightByServer[serverID]?.id == id {
            refreshFlightByServer[serverID] = nil
        }
        return result
    }

    func clearSession(serverID: String) {
        advanceGeneration(for: serverID)
        administratorTokenByServer[serverID] = nil
        tokenExpiredServerIDs.remove(serverID)
    }

    func requestCredential(serverID: String) -> RequestCredential? {
        guard !tokenExpiredServerIDs.contains(serverID) else { return nil }
        let generation = generation(for: serverID)
        guard let token = administratorTokenByServer[serverID] else { return nil }
        return RequestCredential(
            accessToken: token,
            identity: RequestIdentity(
                serverID: serverID,
                principal: .administrator,
                generation: generation
            )
        )
    }

    func isCurrentRequestIdentity(_ identity: RequestIdentity) -> Bool {
        guard identity.generation == generation(for: identity.serverID) else { return false }
        return administratorTokenByServer[identity.serverID] != nil
            && !tokenExpiredServerIDs.contains(identity.serverID)
    }

    func credentialProvider(serverID: String) -> APIClient.CredentialProvider {
        { [weak self] in
            self?.requestCredential(serverID: serverID)
        }
    }

    func handleAuthenticationFailure(_ error: APIError) -> String? {
        guard error.statusCode == 401 || error.statusCode == 403,
              let identity = error.requestIdentity else { return nil }
        guard identity.generation == generation(for: identity.serverID) else {
            return error.message
        }

        guard administratorTokenByServer[identity.serverID] != nil,
              !tokenExpiredServerIDs.contains(identity.serverID) else {
            return error.message
        }
        if error.statusCode == 403 {
            return String(localized: "No admin access")
        }
        advanceGeneration(for: identity.serverID)
        tokenExpiredServerIDs.insert(identity.serverID)
        return error.message
    }

    func scoped(to serverID: String) -> ServerScopedSession {
        ServerScopedSession(state: self, serverID: serverID)
    }

    private func advanceGeneration(for serverID: String) {
        let current = generation(for: serverID)
        precondition(current < UInt64.max, "Request generation exhausted")
        generationByServer[serverID] = current + 1
    }
}

@MainActor
struct ServerScopedSession {
    let state: AdminSessionState
    let serverID: String

    var tokenExpired: Bool {
        state.isTokenExpired(for: serverID)
    }

    func handleAuthenticationFailure(_ error: APIError) -> String? {
        state.handleAuthenticationFailure(error)
    }

    func isCurrentRequestIdentity(_ identity: RequestIdentity) -> Bool {
        identity.serverID == serverID && state.isCurrentRequestIdentity(identity)
    }
}

private struct AdminSessionStateKey: EnvironmentKey {
    static let defaultValue: ServerScopedSession? = nil
}

extension EnvironmentValues {
    var adminSessionState: ServerScopedSession? {
        get { self[AdminSessionStateKey.self] }
        set { self[AdminSessionStateKey.self] = newValue }
    }
}
