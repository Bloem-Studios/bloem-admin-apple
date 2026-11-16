import Foundation
import Security

// How the widgets read the app's per-server sign-in (the maintainer approved live data in widgets, 2026-11-15).
//
// The app's own credential store is not touched: its items stay in the app's private keychain group. Next to
// it the app keeps a *mirror* of each server's tokens in a shared keychain access group
// (`<team prefix>com.bloemstudios.admin.shared`). The mirror has the same protection as the store, readable
// only while the phone is unlocked and never leaving this device, so a widget reads it when iOS refreshes it
// on an unlocked phone and otherwise shows its last data. It holds what the store holds (access token and
// refresh token) and nothing else.
//
// The refresh token rotates on every use, so two processes must not both spend it. Whoever refreshes does so
// under a file lock in the App Group, re-reads the mirror first, and writes the rotated pair back marked with
// who wrote it. When the widget rotated the tokens, the app adopts them from the mirror before it refreshes
// or comes to the foreground; the widget never touches the app's own store.

struct SharedCredential: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case app, widget }

    static let currentVersion = 1

    var version = SharedCredential.currentVersion
    var accessToken: String
    var refreshToken: String?
    var updatedAt: Date
    var source: Source
}

enum SharedCredentialRead: Equatable, Sendable {
    case found(SharedCredential)
    case missing
    /// The phone is locked: the item exists but cannot be read now.
    case locked
}

protocol SharedCredentialStoring: Sendable {
    func read(serverID: String) -> SharedCredentialRead
    func write(_ credential: SharedCredential, serverID: String) throws
    func delete(serverID: String)
}

enum SharedKeychainError: Error, Equatable {
    case unexpectedStatus(operation: String, status: OSStatus)
}

enum SharedKeychain {
    static let service = "com.bloemstudios.admin.widget-credentials.v1"
    static let groupSuffix = "com.bloemstudios.admin.shared"
    /// Info.plist key holding `$(AppIdentifierPrefix)` (the team id and a dot; empty in an unsigned build).
    static let prefixKey = "BloemKeychainGroupPrefix"

    static func accessGroup(bundle: Bundle = .main) -> String {
        let prefix = (bundle.object(forInfoDictionaryKey: prefixKey) as? String) ?? ""
        return prefix + groupSuffix
    }
}

struct KeychainSharedCredentialStore: SharedCredentialStoring {
    let accessGroup: String
    let security: SecurityClient

    init(accessGroup: String = SharedKeychain.accessGroup(), security: SecurityClient = .live) {
        self.accessGroup = accessGroup
        self.security = security
    }

    private func baseQuery(_ serverID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedKeychain.service,
            kSecAttrAccount as String: serverID,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    func read(serverID: String) -> SharedCredentialRead {
        var query = baseQuery(serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = security.copyMatching(query as CFDictionary, &result)
        if status == errSecInteractionNotAllowed { return .locked }
        guard status == errSecSuccess,
              let data = result as? Data,
              let credential = try? JSONDecoder.sharedCredential.decode(SharedCredential.self, from: data),
              credential.version == SharedCredential.currentVersion
        else { return .missing }
        return .found(credential)
    }

    func write(_ credential: SharedCredential, serverID: String) throws {
        let data = try JSONEncoder.sharedCredential.encode(credential)
        // As the app's own store: only while the phone is unlocked, this device only.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = security.update(baseQuery(serverID) as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw SharedKeychainError.unexpectedStatus(operation: "mirror update", status: updated)
        }
        var add = baseQuery(serverID)
        add.merge(attributes) { _, new in new }
        let added = security.add(add as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw SharedKeychainError.unexpectedStatus(operation: "mirror add", status: added)
        }
    }

    func delete(serverID: String) {
        _ = security.delete(baseQuery(serverID) as CFDictionary)
    }
}

private extension JSONEncoder {
    static let sharedCredential: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

private extension JSONDecoder {
    static let sharedCredential: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// A lock across the app and the widget extension, so only one of them spends a refresh token at a time.
/// It is an exclusive `flock` on a file in the App Group container; without the container there is no lock
/// and the caller goes ahead.
struct CredentialRefreshLock: Sendable {
    static let fileName = "credential-refresh.lock"

    /// A held lock. Releasing twice is harmless, and a dropped one releases itself.
    final class Held: @unchecked Sendable {
        private var descriptor: Int32
        private var isHeld: Bool

        fileprivate init(descriptor: Int32, isHeld: Bool) {
            self.descriptor = descriptor
            self.isHeld = isHeld
        }

        /// False when the lock could not be taken (no container, or the other process held it past the timeout).
        var isLocked: Bool { isHeld }

        func release() {
            guard descriptor >= 0 else { return }
            if isHeld { flock(descriptor, LOCK_UN) }
            close(descriptor)
            descriptor = -1
            isHeld = false
        }

        deinit { release() }
    }

    let fileURL: URL?

    static func appGroup() -> CredentialRefreshLock {
        CredentialRefreshLock(fileURL: AppGroup.containerURL?.appendingPathComponent(fileName))
    }

    /// Waits up to `timeout` for the other process. After that it returns without the lock, because a stuck
    /// lock must never stop a refresh for good; the callers re-read the tokens once they have the answer.
    func acquire(timeout: Duration = .seconds(15)) async -> Held {
        guard let path = fileURL?.path else { return Held(descriptor: -1, isHeld: false) }
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return Held(descriptor: -1, isHeld: false) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return Held(descriptor: descriptor, isHeld: true) }
            if clock.now >= deadline { return Held(descriptor: descriptor, isHeld: false) }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
