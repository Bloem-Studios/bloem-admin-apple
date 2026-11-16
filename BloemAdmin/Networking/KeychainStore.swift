import Foundation
import Security

enum KeychainStore {
    static let accessTokenService = "com.bloemstudios.admin.token"
    static let refreshTokenService = "com.bloemstudios.admin.refreshtoken"

    static func setToken(_ token: String, forServerID id: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id,
            kSecAttrService as String: accessTokenService,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        // Device-only and unavailable whenever the device is locked.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw APIError(statusCode: -1, message: "Keychain write failed (\(status))")
        }
    }

    static func token(forServerID id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id,
            kSecAttrService as String: accessTokenService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken(forServerID id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id,
            kSecAttrService as String: accessTokenService,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Refresh token
    //
    // Stored under a DISTINCT Keychain service (never mixed with the access
    // token above) but keyed by the same per-server `id`, with the same
    // Keychain-only, never-logged, when-unlocked-this-device-only
    // discipline. The refresh token is single-use server-side — every
    // successful `/api/v2/auth/refresh` call rotates it — so callers MUST
    // overwrite this via `setRefreshToken` after every successful refresh,
    // not just after login.

    static func setRefreshToken(_ token: String, forServerID id: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id,
            kSecAttrService as String: refreshTokenService,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw APIError(statusCode: -1, message: "Keychain write failed (\(status))")
        }
    }

    static func refreshToken(forServerID id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id,
            kSecAttrService as String: refreshTokenService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteRefreshToken(forServerID id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id,
            kSecAttrService as String: refreshTokenService,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func legacyToken(forServerID id: String, securityClient: SecurityClient) throws -> String? {
        try legacyValue(forServerID: id, service: accessTokenService, securityClient: securityClient)
    }

    static func legacyRefreshToken(forServerID id: String, securityClient: SecurityClient) throws -> String? {
        try legacyValue(forServerID: id, service: refreshTokenService, securityClient: securityClient)
    }

    static func deleteLegacyToken(forServerID id: String, securityClient: SecurityClient) throws {
        try deleteLegacyValue(forServerID: id, service: accessTokenService, securityClient: securityClient)
    }

    static func deleteLegacyRefreshToken(forServerID id: String, securityClient: SecurityClient) throws {
        try deleteLegacyValue(forServerID: id, service: refreshTokenService, securityClient: securityClient)
    }

    private static func legacyValue(
        forServerID id: String,
        service: String,
        securityClient: SecurityClient
    ) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = securityClient.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.unexpectedStatus(operation: "legacy read", status: status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialStoreError.invalidCredentialPayload
        }
        return value
    }

    private static func deleteLegacyValue(
        forServerID id: String,
        service: String,
        securityClient: SecurityClient
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id,
            kSecAttrService as String: service,
        ]
        let status = securityClient.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.unexpectedStatus(operation: "legacy delete", status: status)
        }
    }
}
