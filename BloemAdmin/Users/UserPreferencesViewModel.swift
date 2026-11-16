import Foundation
import Observation

/// What the Preferences tab shows.
enum PreferencesState {
    case loading
    case failed(String)
    /// `definitions` is nil when the server's settings contract could not be read; every value is
    /// then shown but none is edited, because without its type a save could not keep the value's
    /// JSON type.
    case ready(groups: [PreferenceLevelGroup], definitions: [SettingDefinition]?)
}

/// State of one open Preferences tab: what the account's people saved in their apps, by level, and
/// the writes that change it. Every write addresses one row by its full identity and goes through
/// the page's own client, so in All Servers it reaches only the server the page names. After a
/// write the settings are read again.
@Observable
@MainActor
final class UserPreferencesViewModel {
    private(set) var state: PreferencesState = .loading
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    private let admin: UserAdmin
    private let userID: String
    /// Whether the server lists the account's devices (names for the device levels).
    private let devicesAvailable: Bool

    private var profiles: [UserProfile] = []
    private var devices: [UserDevice] = []
    private var libraryNames: [String: String] = [:]
    private var definitions: [SettingDefinition]?
    private var entries: [UserSettingEntry] = []

    init(admin: UserAdmin, userID: String, devicesAvailable: Bool) {
        self.admin = admin
        self.userID = userID
        self.devicesAvailable = devicesAvailable
    }

    func dismissError() { errorMessage = nil }

    var groups: [PreferenceLevelGroup] {
        if case .ready(let groups, _) = state { return groups }
        return []
    }

    var levels: [PreferenceLevel] { groups.flatMap(\.levels) }

    var loadedDefinitions: [SettingDefinition]? {
        if case .ready(_, let definitions) = state { return definitions }
        return nil
    }

    func definition(for key: String) -> SettingDefinition? {
        loadedDefinitions?.first { $0.key == key }
    }

    /// Reads everything; the stored settings are required, the names and the contract are best effort.
    func load() async {
        let client = admin.client
        do {
            entries = try await client.userSettingValues(userID: userID)
        } catch {
            if case .ready = state { return }
            state = .failed(failure(error, fallback: String(localized: "This user's settings couldn't be loaded. Try again.")))
            return
        }
        profiles = (try? await client.userProfiles(userID: userID)) ?? profiles
        if devicesAvailable { devices = (try? await client.userDevices(userID: userID)) ?? devices }
        if let libraries = try? await client.libraryChoices() {
            libraryNames = Dictionary(libraries.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        definitions = (try? await client.settingsContract().definitions) ?? definitions
        publish()
    }

    private func publish() {
        let order = Dictionary(
            (definitions ?? []).enumerated().map { ($0.element.key, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        state = .ready(
            groups: PreferenceLevels.build(entries: entries, profiles: profiles, devices: devices, libraryNames: libraryNames, order: order),
            definitions: definitions
        )
    }

    private func failure(_ error: Error, fallback: String) -> String {
        ErrorMessage.text(for: error, sessionState: admin.sessionState, fallback: fallback, serverName: admin.serverName)
    }

    private func write(_ work: () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        var succeeded = false
        do {
            try await work()
            succeeded = true
        } catch {
            errorMessage = failure(error, fallback: String(localized: "This setting couldn't be saved. Try again."))
        }
        // Whatever happened, the list shows what the server has.
        if let fresh = try? await admin.client.userSettingValues(userID: userID) {
            entries = fresh
            publish()
        }
        isBusy = false
        return succeeded
    }

    /// Stores `value` for `key` at the row's own identity.
    func set(key: String, identity: SettingIdentity, value: JSONValue) async -> Bool {
        await write { try await admin.client.setUserSettingValue(userID: userID, key: key, identity: identity, value: value) }
    }

    /// Adds `keys` to `level`, each starting at the value it replaces. A retry never overwrites what
    /// already landed.
    func add(to level: PreferenceLevel, keys: [String]) async -> Bool {
        guard case .ready = state else { return false }
        let profileEntries = levels.first { $0.kind == .profile && $0.profileID == level.profileID }?.entries ?? []
        let stored = Set(level.entries.map(\.key))
        return await write {
            for key in keys where !stored.contains(key) {
                guard let definition = definition(for: key) else { continue }
                let replaced = PreferenceLevels.replacedValue(level: level, key: key, profileEntries: profileEntries, definition: definition)
                let start = PreferenceLevels.startingValue(replaced: replaced, definition: definition)
                try await admin.client.setUserSettingValue(userID: userID, key: key, identity: level.identity, value: start)
            }
        }
    }

    func remove(_ entry: UserSettingEntry) async -> Bool {
        await write { try await admin.client.deleteUserSettingValue(userID: userID, key: entry.key, identity: entry.identity) }
    }
}
