import Foundation
import Security

// What registering this phone with one saved server returned, kept where the notification service
// extension can read it. The extension runs while the phone is locked, so these items are readable after the
// first unlock (`AfterFirstUnlock`, this device only). That is weaker than the app's own sign-in, which is
// readable only while unlocked, and it is safe to be: the display token opens one thing, the text of this
// device's own notifications (and its retire call). It is never the sign-in, and the extension never sees
// the sign-in.

/// One saved server's registration for this device.
struct PushRegistration: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let currentVersion = 1

    var version = PushRegistration.currentVersion
    var serverID: String
    /// Shown as the subtitle only when "Show details on the lock screen" is on.
    var serverName: String
    var baseURL: URL
    /// The id the server pushes to; every delivery id starts with it.
    var deviceID: String
    /// Reads this device's notification text and retires it. Nothing else.
    var displayToken: String
    /// The account the registration was made for (the sign-in's account id); empty when it could not be read.
    var accountKey: String
    /// A hash of the APNs token this registration was made with, so a rotated token is noticed without
    /// keeping a second copy of it.
    var tokenHash: String
    var registeredAt: Date
    /// Signed out or removed: the server is being told to stop. The extension ignores such a registration.
    var isRetiring = false
    /// How many times telling the server to stop has failed; the registration is dropped after a few.
    var retireAttempts = 0
    /// A kind switch could not be sent to the server; the next pass registers again to send them all.
    var needsResync = false
    /// What the server holds about this phone's widgets (`widgets_placed`, `widget_channels`), as its last answer
    /// said. nil when the server's answer had no such fields: it does not send widget wakes, so nothing is reported.
    var widgetReport: WidgetReport?

    /// Printed and logged without the display token.
    var description: String { "PushRegistration(serverID: \(serverID), deviceID: \(deviceID))" }
    var debugDescription: String { description }
}

enum PushRegistrationRead: Equatable, Sendable {
    case found([PushRegistration])
    /// The phone has not been unlocked since it started: the items exist but cannot be read yet.
    case locked
}

protocol PushRegistrationStoring: Sendable {
    func load() -> PushRegistrationRead
    func save(_ registration: PushRegistration) throws
    func remove(serverID: String)
}

extension PushRegistrationStoring {
    /// The registration for a saved server, whatever its state; nil when there is none or it cannot be read.
    func registration(serverID: String) -> PushRegistration? {
        guard case .found(let all) = load() else { return nil }
        return all.first { $0.serverID == serverID }
    }

    /// The live registration a push's device id belongs to. A registration being retired does not count.
    func registration(deviceID: String) -> PushRegistration? {
        guard case .found(let all) = load() else { return nil }
        return all.first { $0.deviceID == deviceID && !$0.isRetiring }
    }
}

enum PushKeychainError: Error, Equatable {
    case unexpectedStatus(operation: String, status: OSStatus)
}

enum PushKeychain {
    static let service = "com.bloemstudios.admin.push-registrations.v1"
    static let groupSuffix = "com.bloemstudios.admin.shared"
    /// Info.plist key holding `$(AppIdentifierPrefix)` (the team id and a dot; empty in an unsigned build).
    static let prefixKey = "BloemKeychainGroupPrefix"

    static func accessGroup(bundle: Bundle = .main) -> String {
        let prefix = (bundle.object(forInfoDictionaryKey: prefixKey) as? String) ?? ""
        return prefix + groupSuffix
    }
}

struct KeychainPushRegistrationStore: PushRegistrationStoring {
    let accessGroup: String
    let security: SecurityClient

    init(accessGroup: String = PushKeychain.accessGroup(), security: SecurityClient = .live) {
        self.accessGroup = accessGroup
        self.security = security
    }

    private func baseQuery(_ serverID: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PushKeychain.service,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        if let serverID { query[kSecAttrAccount as String] = serverID }
        return query
    }

    func load() -> PushRegistrationRead {
        var query = baseQuery(nil)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = security.copyMatching(query as CFDictionary, &result)
        if status == errSecInteractionNotAllowed { return .locked }
        guard status == errSecSuccess, let items = result as? [Data] else { return .found([]) }
        let all = items.compactMap { data -> PushRegistration? in
            guard let registration = try? JSONDecoder.pushRegistration.decode(PushRegistration.self, from: data),
                  registration.version == PushRegistration.currentVersion else { return nil }
            return registration
        }
        return .found(all.sorted { $0.serverID < $1.serverID })
    }

    func save(_ registration: PushRegistration) throws {
        let data = try JSONEncoder.pushRegistration.encode(registration)
        // Readable after the first unlock, because the extension runs while the phone is locked.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = security.update(baseQuery(registration.serverID) as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw PushKeychainError.unexpectedStatus(operation: "registration update", status: updated)
        }
        var add = baseQuery(registration.serverID)
        add.merge(attributes) { _, new in new }
        let added = security.add(add as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw PushKeychainError.unexpectedStatus(operation: "registration add", status: added)
        }
    }

    func remove(serverID: String) {
        _ = security.delete(baseQuery(serverID) as CFDictionary)
    }
}

private extension JSONEncoder {
    static let pushRegistration: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

private extension JSONDecoder {
    static let pushRegistration: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
