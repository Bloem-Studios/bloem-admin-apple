import Foundation

/// Why a saved server does or does not push to this phone, as Settings explains it.
enum PushStatus: String, Codable, Sendable {
    /// Not asked yet, or the last ask could not be answered.
    case unknown
    /// A plain Silo server: its push service cannot reach this app. Only the local server-down checks apply.
    case plainSilo
    /// A Bloem server that does not offer admin push yet. Retried at the next sign-in or foreground.
    case notAvailableYet
    /// The server pushes only to an administrator's own sign-in.
    case needsAdminAccount
    /// No sign-in for this server, so nothing is known or registered.
    case signedOut
    /// The server can push, but iOS notifications are not allowed for this app.
    case needsPermission
    /// Allowed and ready; the phone has no APNs token yet.
    case waitingForToken
    /// The server pushes to this phone.
    case registered
    /// The server can push, but registering failed. Tried again at the next sign-in or foreground.
    case failed

    /// Whether this server can send kinds beyond the local checks.
    var offersRemoteKinds: Bool {
        switch self {
        case .plainSilo, .notAvailableYet, .signedOut: false
        default: true
        }
    }
}

/// The device-local push choices. None is a secret: which kinds are switched off per saved server, the last
/// known status per server, whether the notification permission was already asked, this installation's id and
/// the last APNs token. Every kind is on until switched off; only the off ones are stored. The two local kinds
/// are stored here too, except that `admin.server_down` is the "Servers to watch" switch (`AlertPreferences`).
struct PushPreferences: @unchecked Sendable {
    private enum Keys {
        static let disabled = "bloem.admin.push.disabledKinds"
        static let statuses = "bloem.admin.push.statuses"
        static let installation = "bloem.admin.push.installationID"
        static let permissionAsked = "bloem.admin.push.permissionAsked"
        static let apnsToken = "bloem.admin.push.apnsToken"
    }

    // UserDefaults is thread-safe but not declared Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// One random id per installation, kept across token refreshes and sign-ins. It names no person or device.
    var installationID: String {
        if let existing = defaults.string(forKey: Keys.installation), existing.count >= 8 { return existing }
        let created = UUID().uuidString
        defaults.set(created, forKey: Keys.installation)
        return created
    }

    var permissionAsked: Bool {
        get { defaults.bool(forKey: Keys.permissionAsked) }
        nonmutating set { defaults.set(newValue, forKey: Keys.permissionAsked) }
    }

    /// The APNs device token iOS last gave, hex.
    var apnsToken: String? {
        get { defaults.string(forKey: Keys.apnsToken).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set { defaults.set(newValue, forKey: Keys.apnsToken) }
    }

    // MARK: Kind switches

    private var disabled: [String: [String]] {
        get {
            defaults.data(forKey: Keys.disabled)
                .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        }
        nonmutating set {
            let clean = newValue.filter { !$0.value.isEmpty }
            if clean.isEmpty {
                defaults.removeObject(forKey: Keys.disabled)
            } else {
                defaults.set(try? JSONEncoder().encode(clean), forKey: Keys.disabled)
            }
        }
    }

    func disabledKinds(serverID: String) -> Set<PushKind> {
        Set((disabled[serverID] ?? []).compactMap(PushKind.init(rawValue:)))
    }

    func isEnabled(_ kind: PushKind, serverID: String) -> Bool {
        !disabledKinds(serverID: serverID).contains(kind)
    }

    func setKind(_ kind: PushKind, enabled: Bool, serverID: String) {
        var kinds = disabledKinds(serverID: serverID)
        if enabled { kinds.remove(kind) } else { kinds.insert(kind) }
        var all = disabled
        all[serverID] = kinds.map(\.rawValue).sorted()
        disabled = all
    }

    /// The kinds a server sends that this phone switched off, for the registration.
    func disabledRemoteKinds(serverID: String) -> [String] {
        disabledKinds(serverID: serverID).filter { !$0.isLocal }.map(\.rawValue).sorted()
    }

    // MARK: Status

    private var statuses: [String: PushStatus] {
        get {
            defaults.data(forKey: Keys.statuses)
                .flatMap { try? JSONDecoder().decode([String: PushStatus].self, from: $0) } ?? [:]
        }
        nonmutating set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Keys.statuses)
            } else {
                defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.statuses)
            }
        }
    }

    func status(serverID: String) -> PushStatus {
        statuses[serverID] ?? .unknown
    }

    func setStatus(_ status: PushStatus?, serverID: String) {
        var all = statuses
        all[serverID] = status
        statuses = all
    }

    /// Forgets everything kept for servers that are no longer saved.
    func retain(serverIDs: Set<String>) {
        let kept = disabled.filter { serverIDs.contains($0.key) }
        if kept.count != disabled.count { disabled = kept }
        let live = statuses.filter { serverIDs.contains($0.key) }
        if live.count != statuses.count { statuses = live }
    }
}
