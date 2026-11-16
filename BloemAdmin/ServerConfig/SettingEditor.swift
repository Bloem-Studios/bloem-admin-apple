import Foundation
import Observation

/// A setting as it was read when the editor opened, with the ETag that guards the save.
struct SettingEditSnapshot: Equatable, Sendable {
    let key: String
    let value: String
    let validator: String
}

/// State of one setting edit. The validator is the `ETag` of `GET /settings/effective`, which covers
/// the whole settings snapshot (`GET /settings/{key}` sends none). It is read when the editor
/// opens and sent as `If-Match`; a save never re-reads first, so a change made elsewhere in
/// between surfaces as a conflict (412, or 428 when the tag is missing) instead of being
/// overwritten. On a conflict the editor re-reads, keeps the draft and offers the current value:
/// the person keeps their edit or takes the server's.
@Observable
@MainActor
final class SettingEditor {
    let key: String
    /// Set in All Servers mode so the sheet and its errors name the server being edited.
    let serverName: String?
    var draft = ""
    private(set) var snapshot: SettingEditSnapshot?
    /// The current server value, read after a conflict.
    private(set) var latest: SettingEditSnapshot?
    private(set) var hasConflict = false
    /// What the server answered to the last successful save; says whether a restart is needed.
    private(set) var receipt: SettingReceipt?
    private(set) var errorMessage: String?
    private(set) var isBusy = false

    init(key: String, serverName: String? = nil) {
        self.key = key
        self.serverName = serverName
    }

    /// "<server> · <key>" in All Servers mode, otherwise just the key.
    var title: String { serverName.map { "\($0) · \(key)" } ?? key }

    /// Conflict text; names the server in All Servers mode.
    var conflictMessage: String {
        guard let serverName else { return String(localized: "Settings changed on the server") }
        return String(localized: "Settings changed on \(serverName)")
    }

    var canSave: Bool {
        guard let snapshot, !isBusy, !hasConflict else { return false }
        return draft != snapshot.value
    }

    func open(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let read = try await readForEdit(client: client)
            snapshot = read
            draft = read.value
            errorMessage = nil
        } catch {
            errorMessage = message(for: error, sessionState: sessionState)
        }
    }

    /// Returns true when the value was saved.
    func save(client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        guard canSave, let snapshot else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            receipt = try await client.updateSetting(key: key, value: draft, validator: snapshot.validator)
            return true
        } catch let error as APIError where error.statusCode == 412 || error.statusCode == 428 {
            hasConflict = true
            latest = nil
            await reviewCurrent(client: client, sessionState: sessionState)
            return false
        } catch {
            errorMessage = message(for: error, sessionState: sessionState)
            return false
        }
    }

    func reviewCurrent(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        isBusy = true
        defer { isBusy = false }
        do {
            latest = try await readForEdit(client: client)
            errorMessage = nil
        } catch {
            errorMessage = message(for: error, sessionState: sessionState)
        }
    }

    /// Takes the current server revision as the base for the next save; the draft stays as typed.
    func adoptCurrent() {
        guard let latest else { return }
        snapshot = latest
        self.latest = nil
        hasConflict = false
    }

    /// Takes the server's current value as the draft, along with its revision.
    func useCurrent() {
        guard let latest else { return }
        snapshot = latest
        draft = latest.value
        self.latest = nil
        hasConflict = false
    }

    private func readForEdit(client: APIClient) async throws -> SettingEditSnapshot {
        let (values, validator) = try await client.effectiveSettings()
        guard let validator, !validator.isEmpty else {
            throw SettingEditorError.missingValidator
        }
        return SettingEditSnapshot(key: key, value: values[key] ?? "", validator: validator)
    }

    private func message(for error: Error, sessionState: ServerScopedSession?) -> String {
        if error is SettingEditorError {
            return ErrorMessage.named(
                String(localized: "The server did not send a version for its settings, so this setting cannot be changed safely. Update the server, then try again"),
                serverName: serverName
            )
        }
        return ErrorMessage.text(
            for: error, sessionState: sessionState,
            fallback: String(localized: "The setting couldn't be saved. Try again"), serverName: serverName
        )
    }
}

private enum SettingEditorError: Error {
    case missingValidator
}
