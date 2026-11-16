import Foundation
import Security

struct ServerCredentials: Codable, Sendable, Equatable {
    static let currentVersion = 1

    let version: Int
    let accessToken: String
    let refreshToken: String?
}

protocol CredentialStoring: Sendable {
    func credentials(for serverID: String) throws -> ServerCredentials?
    func save(_ credentials: ServerCredentials, for serverID: String) throws
    func deleteCredentials(for serverID: String) throws
}

enum KeychainCredentialStoreError: Error, LocalizedError {
    case unexpectedStatus(operation: String, status: OSStatus)
    case invalidCredentialPayload

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let operation, let status):
            return "Keychain \(operation) failed (\(status))."
        case .invalidCredentialPayload:
            return "The saved credential record could not be verified."
        }
    }
}

/// Every live store instance shares this coordinator so one server's complete
/// read/migrate/save/delete transaction cannot interleave with another window's
/// operation for that same server. Separate server IDs retain independent locks
/// and can still progress in parallel. Tests may inject an isolated instance.
final class CredentialOperationCoordinator: @unchecked Sendable {
    static let shared = CredentialOperationCoordinator()

    private let registryLock = NSLock()
    private var serverLocks: [String: NSLock] = [:]

    func withLock<Result>(for serverID: String, _ operation: () throws -> Result) rethrows -> Result {
        let serverLock = registryLock.withLock {
            if let existing = serverLocks[serverID] {
                return existing
            }
            let created = NSLock()
            serverLocks[serverID] = created
            return created
        }
        return try serverLock.withLock(operation)
    }
}

struct KeychainCredentialStore: CredentialStoring {
    static let service = "com.bloemstudios.admin.credentials.v1"

    private let securityClient: SecurityClient
    private let operationCoordinator: CredentialOperationCoordinator

    init(
        securityClient: SecurityClient = .live,
        operationCoordinator: CredentialOperationCoordinator = .shared
    ) {
        self.securityClient = securityClient
        self.operationCoordinator = operationCoordinator
    }

    func credentials(for serverID: String) throws -> ServerCredentials? {
        try operationCoordinator.withLock(for: serverID) {
            try credentialsWhileLocked(for: serverID)
        }
    }

    func save(_ credentials: ServerCredentials, for serverID: String) throws {
        try operationCoordinator.withLock(for: serverID) {
            try saveWhileLocked(credentials, for: serverID)
        }
    }

    func deleteCredentials(for serverID: String) throws {
        try operationCoordinator.withLock(for: serverID) {
            try deleteCredentialsWhileLocked(for: serverID)
        }
    }

    private func credentialsWhileLocked(for serverID: String) throws -> ServerCredentials? {
        if let credentials = try readCombinedCredentials(for: serverID) {
            try deleteLegacyCredentialsWhileLocked(for: serverID)
            return credentials
        }
        return try migrateLegacyCredentials(for: serverID)
    }

    private func saveWhileLocked(_ credentials: ServerCredentials, for serverID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = baseQuery(for: serverID)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = securityClient.update(
            query as CFDictionary,
            updateAttributes as CFDictionary
        )

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw statusError("update", updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = securityClient.add(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw statusError("add", addStatus)
        }
    }

    private func deleteCredentialsWhileLocked(for serverID: String) throws {
        var firstError: Error?

        do {
            try deleteCombinedCredentials(for: serverID)
        } catch {
            firstError = error
        }
        do {
            try KeychainStore.deleteLegacyToken(
                forServerID: serverID,
                securityClient: securityClient
            )
        } catch {
            if firstError == nil { firstError = error }
        }
        do {
            try KeychainStore.deleteLegacyRefreshToken(
                forServerID: serverID,
                securityClient: securityClient
            )
        } catch {
            if firstError == nil { firstError = error }
        }

        if let firstError {
            throw firstError
        }
    }

    private func deleteCombinedCredentials(for serverID: String) throws {
        let status = securityClient.delete(baseQuery(for: serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw statusError("delete", status)
        }
    }

    private func readCombinedCredentials(for serverID: String) throws -> ServerCredentials? {
        var query = baseQuery(for: serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = securityClient.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw statusError("read", status)
        }
        guard let data = result as? Data,
              let credentials = try? JSONDecoder().decode(ServerCredentials.self, from: data) else {
            throw KeychainCredentialStoreError.invalidCredentialPayload
        }
        let upgradeStatus = securityClient.update(
            baseQuery(for: serverID) as CFDictionary,
            [
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary
        )
        guard upgradeStatus == errSecSuccess else {
            throw statusError("accessibility upgrade", upgradeStatus)
        }
        return credentials
    }

    private func migrateLegacyCredentials(for serverID: String) throws -> ServerCredentials? {
        guard let accessToken = try KeychainStore.legacyToken(
            forServerID: serverID,
            securityClient: securityClient
        ) else {
            return nil
        }
        let refreshToken = try KeychainStore.legacyRefreshToken(
            forServerID: serverID,
            securityClient: securityClient
        )
        let migrated = ServerCredentials(
            version: ServerCredentials.currentVersion,
            accessToken: accessToken,
            refreshToken: refreshToken
        )

        try saveWhileLocked(migrated, for: serverID)
        guard try readCombinedCredentials(for: serverID) == migrated else {
            throw KeychainCredentialStoreError.invalidCredentialPayload
        }
        try deleteLegacyCredentialsWhileLocked(for: serverID)
        return migrated
    }

    private func deleteLegacyCredentialsWhileLocked(for serverID: String) throws {
        var firstError: Error?

        do {
            try KeychainStore.deleteLegacyToken(
                forServerID: serverID,
                securityClient: securityClient
            )
        } catch {
            firstError = error
        }
        do {
            try KeychainStore.deleteLegacyRefreshToken(
                forServerID: serverID,
                securityClient: securityClient
            )
        } catch {
            if firstError == nil { firstError = error }
        }

        if let firstError {
            throw firstError
        }
    }

    private func baseQuery(for serverID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: serverID,
            kSecAttrService as String: Self.service,
        ]
    }

    private func statusError(_ operation: String, _ status: OSStatus) -> KeychainCredentialStoreError {
        .unexpectedStatus(operation: operation, status: status)
    }
}
