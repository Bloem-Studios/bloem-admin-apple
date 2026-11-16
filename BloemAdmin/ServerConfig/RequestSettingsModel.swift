import Foundation
import Observation

/// The request settings page's state: the server-wide request defaults with the `ETag` that guards
/// their write. Edits are measured against the snapshot they began on, as in `ServerSettingsModel`: a
/// refresh while edits exist reads the server's latest without moving that baseline, and a save that
/// lost a race (412) keeps the edits and offers the server's values.
@Observable
@MainActor
final class RequestSettingsModel {
    let serverName: String?
    private(set) var base: RequestSettings?
    private(set) var baseValidator: String?
    private(set) var latest: RequestSettings?
    private(set) var latestValidator: String?
    /// The settings as edited; equal to `base` when there is no edit.
    private(set) var draft: RequestSettings?
    private(set) var hasLoaded = false
    private(set) var loadFailure: ServerSectionFailure?
    private(set) var refreshError: String?
    private(set) var isSaving = false
    private(set) var hasConflict = false
    private(set) var saveError: String?
    private(set) var didSave = false
    private var requestID = 0

    init(serverName: String? = nil) {
        self.serverName = serverName
    }

    var isDirty: Bool { draft != nil && draft != base }

    /// The server changed the settings while edits were in progress.
    var isStale: Bool {
        guard isDirty, let latestValidator, let baseValidator else { return false }
        return latestValidator != baseValidator
    }

    var showsConflict: Bool { hasConflict || isStale }

    /// Why the limit cannot be saved, in words; nil when it can.
    var limitProblem: String? {
        guard let draft else { return nil }
        return draft.globalMaxRequests < 0 ? String(localized: "Use a whole number, 0 or more") : nil
    }

    var windowProblem: String? {
        guard let draft else { return nil }
        return draft.globalWindowDays < 1 ? String(localized: "Use at least 1 day") : nil
    }

    var canSave: Bool { isDirty && !isSaving && limitProblem == nil && windowProblem == nil }

    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        requestID += 1
        let token = requestID
        do {
            let (settings, validator) = try await client.requestSettings()
            guard token == requestID else { return }
            latest = settings
            latestValidator = validator
            if !isDirty {
                base = settings
                baseValidator = validator
                draft = settings
            }
            loadFailure = nil
            refreshError = nil
            hasLoaded = true
        } catch {
            guard token == requestID else { return }
            let fallback = String(localized: "Could not load the request settings. Check your connection and try again")
            if hasLoaded {
                refreshError = ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback, serverName: serverName)
            } else {
                loadFailure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: fallback, serverName: serverName)
            }
        }
    }

    /// Changes one field of the edit.
    func edit(_ change: (inout RequestSettings) -> Void) {
        guard var current = draft else { return }
        change(&current)
        draft = current
        saveError = nil
        didSave = false
    }

    func discard() {
        draft = base
        hasConflict = false
        saveError = nil
    }

    func save(client: APIClient, sessionState: ServerScopedSession? = nil) async -> SettingsSaveOutcome {
        guard !isSaving else { return .failed }
        guard isDirty, let draft else { return .nothingToSave }
        guard let baseValidator, !baseValidator.isEmpty else {
            saveError = ErrorMessage.named(
                String(localized: "The server did not send a version for these settings, so they cannot be changed safely. Update the server, then try again"),
                serverName: serverName
            )
            return .failed
        }
        isSaving = true
        saveError = nil
        didSave = false
        defer { isSaving = false }
        do {
            let (saved, validator) = try await client.updateRequestSettings(draft, validator: baseValidator)
            base = saved
            self.draft = saved
            latest = saved
            self.baseValidator = validator
            latestValidator = validator
            hasConflict = false
            didSave = true
            if validator == nil { await load(client: client, sessionState: sessionState) }
            return .saved
        } catch let error as APIError where error.statusCode == 412 || error.statusCode == 428 {
            hasConflict = true
            await load(client: client, sessionState: sessionState)
            return .conflict
        } catch {
            saveError = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "Could not save the request settings. Check your connection and try again"),
                serverName: serverName
            )
            return .failed
        }
    }

    /// Keeps the edits and saves them over what the server has now.
    func keepMyChanges() {
        base = latest
        baseValidator = latestValidator
        hasConflict = false
        saveError = nil
    }

    /// Takes what the server has now and drops the edits.
    func useServerValues() {
        base = latest
        baseValidator = latestValidator
        draft = latest
        hasConflict = false
        saveError = nil
    }
}
