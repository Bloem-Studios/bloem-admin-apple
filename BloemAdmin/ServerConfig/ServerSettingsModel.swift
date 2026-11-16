import Foundation
import Observation

/// What a save did, for the line under the save bar.
struct SettingsSaveNotice: Equatable, Sendable {
    let keys: [String]
    let restartRequired: Bool
    /// The labels of the saved settings that wait for a restart.
    let restartLabels: [String]
}

/// How a save ended.
enum SettingsSaveOutcome: Equatable, Sendable {
    case saved
    case nothingToSave
    /// The settings changed on the server since they were read; the person's edits are kept.
    case conflict
    case failed
}

/// One server's settings for the named pages: the effective values with their validator, which keys
/// wait for a restart, which secrets are set, the server status, and the person's unsaved edits.
///
/// The validator is the `ETag` of `GET /settings/effective`; it covers the whole snapshot and guards
/// `PUT /settings` through `If-Match`. Edits are measured against the snapshot they began on (`base`):
/// a refresh while edits exist never moves that baseline, so a save that lost a race to another
/// administrator is refused (412) instead of overwriting their change. The refresh still reads the
/// server's latest values, which is how the page can show what changed.
@Observable
@MainActor
final class ServerSettingsModel {
    /// Set in All servers mode so errors name the server.
    let serverName: String?

    // The latest read, and the snapshot edits are measured against.
    private(set) var latest: [String: String] = [:]
    private(set) var latestValidator: String?
    private(set) var base: [String: String] = [:]
    private(set) var baseValidator: String?
    private(set) var restartKeys: RestartKeys = .none
    private(set) var sensitive: SensitiveStatus = .none
    /// The server could not say which secrets are set; the secret rows say so and still accept a new value.
    private(set) var sensitiveUnavailable = false
    private(set) var status: ServerStatus?
    private(set) var hasLoaded = false
    /// Why the first read failed; the page shows it in place of its content.
    private(set) var loadFailure: ServerSectionFailure?
    /// Why a later refresh failed while the earlier values stay on screen.
    private(set) var refreshError: String?

    /// Unsaved edits by key. A secret's edit is the new value, or "" to clear it.
    private(set) var drafts: [String: String] = [:]
    private(set) var isSaving = false
    /// True after a save was refused because the settings changed on the server.
    private(set) var hasConflict = false
    private(set) var saveError: String?
    private(set) var lastSave: SettingsSaveNotice?

    private(set) var isRestarting = false
    private(set) var restartNotice: String?
    private(set) var restartError: String?

    private var requestID = 0

    init(serverName: String? = nil) {
        self.serverName = serverName
    }

    // MARK: Reading

    /// Reads the settings, restart keys, secret status and server status. A refresh never replaces the
    /// baseline of edits in progress; see the type's comment.
    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        requestID += 1
        let token = requestID
        do {
            async let effective = client.effectiveSettings()
            async let restart = client.restartKeys()
            async let secrets = client.sensitiveStatus()
            async let serverStatus = client.serverStatus()
            let (values, validator) = try await effective
            let loadedStatus = try await serverStatus
            let loadedRestart = try? await restart
            let loadedSecrets = try? await secrets
            guard token == requestID else { return }
            latest = values
            latestValidator = validator
            if drafts.isEmpty {
                base = values
                baseValidator = validator
            }
            if let loadedRestart { restartKeys = loadedRestart }
            if let loadedSecrets { sensitive = loadedSecrets }
            sensitiveUnavailable = loadedSecrets == nil
            status = loadedStatus
            loadFailure = nil
            refreshError = nil
            hasLoaded = true
        } catch {
            guard token == requestID else { return }
            let fallback = String(localized: "Could not load settings. Check your connection and try again")
            if hasLoaded {
                refreshError = ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback, serverName: serverName)
            } else {
                loadFailure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: fallback, serverName: serverName)
            }
        }
    }

    /// Reads only the server status (restart state, start time), for the status poll.
    func refreshStatus(client: APIClient) async {
        if let loaded = try? await client.serverStatus() { status = loaded }
    }

    // MARK: Values

    /// What a control shows: the edit, else the value from the baseline snapshot.
    func value(for key: String) -> String {
        drafts[key] ?? base[key] ?? ""
    }

    /// Whether the baseline snapshot has a value for the key (a secret never does).
    func hasStoredValue(_ key: String) -> Bool {
        base[key] != nil
    }

    func isDirty(_ key: String) -> Bool {
        drafts[key] != nil
    }

    func dirtyKeys(in keys: [String]) -> [String] {
        keys.filter(isDirty)
    }

    var hasUnsavedEdits: Bool { !drafts.isEmpty }

    /// Stages an edit. An edit that puts a plain setting back to its baseline value is no edit; a
    /// secret's edit always stays, since its current value is not known.
    func setDraft(_ value: String, for key: String, secret: Bool = false) {
        if !secret, (base[key] ?? "") == value {
            drafts[key] = nil
        } else {
            drafts[key] = value
        }
        saveError = nil
        lastSave = nil
    }

    func discard(keys: [String]) {
        for key in keys { drafts[key] = nil }
        saveError = nil
        if drafts.isEmpty { hasConflict = false }
    }

    func requiresRestart(_ key: String) -> Bool { restartKeys.requiresRestart(key) }

    func isManagedByEnvironment(_ key: String) -> Bool { sensitive.managedByEnv.contains(key) }

    /// Whether a secret setting holds a value, counting a pending edit.
    func isSecretSet(_ key: String) -> Bool {
        if let draft = drafts[key] { return !draft.isEmpty }
        return sensitive.configured.contains(key)
    }

    /// Stored keys the catalogue does not name, for the Other settings list.
    var otherKeys: [String] {
        base.keys.filter { !SettingsCatalogue.knownKeys.contains($0) }.sorted()
    }

    // MARK: Changes made elsewhere

    /// Edits are in progress and the server's settings are no longer the ones they began on.
    var isStale: Bool {
        guard !drafts.isEmpty, let latestValidator, let baseValidator else { return false }
        return latestValidator != baseValidator
    }

    /// Edited keys whose value on the server differs from the one the edit began on.
    var staleKeys: Set<String> {
        Set(drafts.keys.filter { (latest[$0] ?? "") != (base[$0] ?? "") && !isSecretKey($0) })
    }

    /// The value the server has now, for a key that changed there.
    func serverValue(for key: String) -> String? {
        staleKeys.contains(key) ? latest[key] : nil
    }

    var showsConflict: Bool { hasConflict || isStale }

    /// Keeps the person's edits and writes them over the server's current settings: the baseline
    /// moves to what the server has now.
    func keepMyChanges() {
        base = latest
        baseValidator = latestValidator
        for key in drafts.keys where !isSecretKey(key) && drafts[key] == base[key] { drafts[key] = nil }
        hasConflict = false
        saveError = nil
    }

    /// Takes the server's values for the keys that changed there and keeps the other edits.
    func useServerValues() {
        for key in staleKeys { drafts[key] = nil }
        base = latest
        baseValidator = latestValidator
        hasConflict = false
        saveError = nil
    }

    private func isSecretKey(_ key: String) -> Bool {
        SettingsCatalogue.spec(forKey: key)?.spec.isSecret ?? false
    }

    // MARK: Saving

    /// Writes the edited settings among `keys` in one `PUT /settings`, guarded by the baseline validator.
    func save(keys: [String], client: APIClient, sessionState: ServerScopedSession? = nil) async -> SettingsSaveOutcome {
        guard !isSaving else { return .failed }
        let dirty = dirtyKeys(in: keys)
        guard !dirty.isEmpty else { return .nothingToSave }
        guard let baseValidator, !baseValidator.isEmpty else {
            saveError = ErrorMessage.named(
                String(localized: "The server did not send a version for its settings, so they cannot be changed safely. Update the server, then try again"),
                serverName: serverName
            )
            return .failed
        }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let sent = Dictionary(uniqueKeysWithValues: dirty.map { ($0, drafts[$0] ?? "") })
        do {
            let result = try await client.updateSettings(values: sent, validator: baseValidator)
            applySaved(sent: sent, result: result)
            if result.validator == nil { await load(client: client, sessionState: sessionState) }
            await refreshStatus(client: client)
            let restartKeysSaved = result.restartRequiredKeys.isEmpty
                ? (result.restartRequired ? dirty.filter(requiresRestart) : [])
                : result.restartRequiredKeys
            lastSave = SettingsSaveNotice(
                keys: dirty, restartRequired: result.restartRequired,
                restartLabels: restartKeysSaved.map(SettingsCatalogue.label(forKey:))
            )
            return .saved
        } catch let error as APIError where error.statusCode == 412 || error.statusCode == 428 {
            hasConflict = true
            await load(client: client, sessionState: sessionState)
            return .conflict
        } catch let error as APIError where error.code == "break_glass_required" {
            saveError = ErrorMessage.named(
                String(localized: "Password sign-in can't be turned off yet: no admin is a break-glass account. Open an admin on the Users page and turn on Break-glass account first, so someone can still sign in if the provider is down"),
                serverName: serverName
            )
            return .failed
        } catch {
            saveError = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "Could not save settings. Check your connection and try again"),
                serverName: serverName
            )
            return .failed
        }
    }

    private func applySaved(sent: [String: String], result: SettingsWriteResult) {
        for (key, value) in sent {
            let saved = result.values[key] ?? value
            if isSecretKey(key) {
                // Whether a secret is set follows what was sent, not what the answer echoes.
                var configured = Set(sensitive.configured)
                if value.isEmpty { configured.remove(key) } else { configured.insert(key) }
                sensitive = SensitiveStatus(configured: configured.sorted(), managedByEnv: sensitive.managedByEnv)
            } else {
                base[key] = saved
                latest[key] = saved
            }
            drafts[key] = nil
        }
        if let validator = result.validator {
            baseValidator = validator
            latestValidator = validator
        }
        hasConflict = false
    }

    // MARK: Restart

    /// Asks the server to restart. The notice says whether this request started it or one was already pending.
    func restartServer(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard !isRestarting else { return }
        isRestarting = true
        restartNotice = nil
        restartError = nil
        defer { isRestarting = false }
        do {
            let receipt = try await client.requestServerRestart()
            restartNotice = RestartStatus.receiptNotice(receipt)
            await refreshStatus(client: client)
        } catch {
            restartError = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "Could not confirm the restart. Check the server status or restart it yourself"),
                serverName: serverName
            )
        }
    }
}
