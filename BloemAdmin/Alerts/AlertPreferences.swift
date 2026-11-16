import Foundation

/// The alert settings of this device, kept in UserDefaults: not secrets, and readable after the first
/// unlock, which is when a background check runs. Everything is off until the admin turns it on.
struct AlertPreferences: @unchecked Sendable {
    private enum Keys {
        static let enabled = "bloem.admin.alerts.enabled"
        static let servers = "bloem.admin.alerts.servers"
        static let details = "bloem.admin.alerts.showsDetails"
        static let states = "bloem.admin.alerts.states"
    }

    // UserDefaults is thread-safe but not declared Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The master switch.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    /// Whether a lock screen may show when and why a server stopped answering. Per device.
    var showsDetails: Bool {
        get { defaults.bool(forKey: Keys.details) }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.details)
            // The widgets and the notification extension read this device's choice from the App Group.
            if defaults === UserDefaults.standard {
                WidgetSettingsSync.write()
                PushSettingsMirror.sync(showsDetails: newValue)
            }
        }
    }

    var enabledServerIDs: Set<String> {
        Set(defaults.stringArray(forKey: Keys.servers) ?? [])
    }

    func isServerEnabled(_ id: String) -> Bool {
        enabledServerIDs.contains(id)
    }

    func setServer(_ id: String, enabled: Bool) {
        var ids = enabledServerIDs
        if enabled { ids.insert(id) } else { ids.remove(id) }
        defaults.set(ids.sorted(), forKey: Keys.servers)
    }

    /// The saved servers that get alerts: none while the master switch is off.
    func checkableServerIDs(saved: Set<String>) -> Set<String> {
        isEnabled ? enabledServerIDs.intersection(saved) : []
    }

    // MARK: Per-server state

    private var states: [String: ServerAlertState] {
        get {
            defaults.data(forKey: Keys.states)
                .flatMap { try? JSONDecoder().decode([String: ServerAlertState].self, from: $0) } ?? [:]
        }
        nonmutating set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Keys.states)
            } else {
                defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.states)
            }
        }
    }

    func state(for id: String) -> ServerAlertState {
        states[id] ?? ServerAlertState()
    }

    func setState(_ state: ServerAlertState, for id: String) {
        var all = states
        all[id] = state
        states = all
    }

    func clearStates() {
        states = [:]
    }

    /// Forgets every server that is no longer saved, so nothing about a removed server is kept or checked.
    func prune(keeping saved: Set<String>) {
        let kept = enabledServerIDs.intersection(saved)
        if kept != enabledServerIDs { defaults.set(kept.sorted(), forKey: Keys.servers) }
        let all = states
        let remaining = all.filter { saved.contains($0.key) }
        if remaining.count != all.count { states = remaining }
    }
}
