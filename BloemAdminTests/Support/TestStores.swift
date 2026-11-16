import Foundation
import os
@testable import BloemAdmin

enum TestError: Error { case expected }

extension AdminServer {
    static let fixture = AdminServer(
        id: "test-server",
        baseURL: URL(string: "https://example.test")!,
        displayName: "Example"
    )
}

extension ServerCredentials {
    static let fixture = ServerCredentials(
        version: ServerCredentials.currentVersion,
        accessToken: "access-1",
        refreshToken: "refresh-1"
    )
    static let rotated = ServerCredentials(
        version: ServerCredentials.currentVersion,
        accessToken: "access-2",
        refreshToken: "refresh-2"
    )
}

@MainActor
func makeIsolatedServerStore() -> ServerStore {
    ServerStore(
        metadataStore: InMemoryServerMetadataStore(),
        credentialStore: InMemoryCredentialStore()
    )
}

final class InMemoryCredentialStore: CredentialStoring, Sendable {
    struct SaveCall: Equatable {
        let credentials: ServerCredentials
        let serverID: String
    }

    private struct State {
        var credentialsByServerID: [String: ServerCredentials]
        var saveCalls: [SaveCall] = []
        var loadError: Error?
        var saveError: Error?
        var deleteError: Error?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(
        credentialsByServerID: [String: ServerCredentials] = [:],
        loadError: Error? = nil,
        saveError: Error? = nil,
        deleteError: Error? = nil
    ) {
        state = OSAllocatedUnfairLock(initialState: State(
            credentialsByServerID: credentialsByServerID,
            loadError: loadError,
            saveError: saveError,
            deleteError: deleteError
        ))
    }

    var saveCalls: [SaveCall] {
        state.withLock { $0.saveCalls }
    }

    func credentials(for serverID: String) throws -> ServerCredentials? {
        try state.withLock { state in
            if let error = state.loadError { throw error }
            return state.credentialsByServerID[serverID]
        }
    }

    func save(_ credentials: ServerCredentials, for serverID: String) throws {
        try state.withLock { state in
            if let error = state.saveError { throw error }
            state.credentialsByServerID[serverID] = credentials
            state.saveCalls.append(SaveCall(credentials: credentials, serverID: serverID))
        }
    }

    func deleteCredentials(for serverID: String) throws {
        try state.withLock { state in
            if let error = state.deleteError { throw error }
            state.credentialsByServerID.removeValue(forKey: serverID)
        }
    }
}

final class InMemoryServerMetadataStore: ServerMetadataStoring, Sendable {
    private struct State {
        var servers: [AdminServer]
        var loadError: Error?
        var saveError: Error?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(
        servers: [AdminServer] = [],
        loadError: Error? = nil,
        saveError: Error? = nil
    ) {
        state = OSAllocatedUnfairLock(initialState: State(
            servers: servers,
            loadError: loadError,
            saveError: saveError
        ))
    }

    var saveError: Error? {
        get { state.withLock { $0.saveError } }
        set { state.withLock { $0.saveError = newValue } }
    }

    func loadServers() throws -> [AdminServer] {
        try state.withLock { state in
            if let error = state.loadError { throw error }
            return state.servers
        }
    }

    func saveServers(_ servers: [AdminServer]) throws {
        try state.withLock { state in
            if let error = state.saveError { throw error }
            state.servers = servers
        }
    }
}
