import Foundation
import Observation

extension SectionModel where Payload == BackupsPage {
    /// The Backups page of one server (`serverName` set in All servers mode).
    static func backups(serverName: String? = nil) -> SectionModel<BackupsPage> {
        SectionModel<BackupsPage>(serverName: serverName, loadFallback: String(localized: "Could not load backups.")) { client in
            try await client.backupsPage()
        }
    }

    @discardableResult
    func backUpNow(client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        let started = await act(id: "backup-now", fallback: String(localized: "Could not start the backup."), client: client, sessionState: sessionState) {
            try await $0.startBackup()
        }
        if started { AdminJobActivityTracker.shared.backupStarted(serverID: sessionState?.serverID) }
        return started
    }

    @discardableResult
    func deleteBackup(id: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        await act(id: id, fallback: String(localized: "Could not delete this backup."), client: client, sessionState: sessionState) {
            try await $0.deleteBackup(id: id)
        }
    }
}

extension APIClient {
    /// The overview plus the backup task's next run. The task read is for the next-run line only, so its
    /// failure leaves the overview as it is.
    func backupsPage() async throws -> BackupsPage {
        let overview = try await backupsOverview()
        let task = try? await adminTask(key: "backup")
        return BackupsPage(
            overview: overview, taskNextRunAt: task?.nextRunAt,
            taskTimeOfDay: task?.triggers.first { $0.type == "daily" }?.timeOfDay
        )
    }
}

/// The typed editor for `backup.enabled`, `backup.time` and `backup.keep`. The settings snapshot's ETag
/// (`GET /settings/effective`) read when the editor opens is the `If-Match` of the first write; every
/// further write uses a version read after the one before it, because each write changes the snapshot.
/// A conflict stops the save, keeps what was typed and offers the current values.
@Observable
@MainActor
final class BackupSettingsEditor {
    static let keepRange = 1...60
    static let enabledKey = "backup.enabled"
    static let timeKey = "backup.time"
    static let keepKey = "backup.keep"

    var isEnabled = true
    /// Minutes after midnight.
    var minutes = 4 * 60
    var keep = 7

    private(set) var hasValues = false
    private(set) var hasConflict = false
    private(set) var errorMessage: String?
    private(set) var isBusy = false
    /// Set when a save worked.
    private(set) var restartRequired = false

    private var loaded: (enabled: Bool, minutes: Int, keep: Int)?
    private var validator: String?

    var timeText: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    private var changedKeys: [(key: String, value: String)] {
        guard let loaded else { return [] }
        var changes: [(String, String)] = []
        if isEnabled != loaded.enabled { changes.append((Self.enabledKey, isEnabled ? "true" : "false")) }
        if minutes != loaded.minutes { changes.append((Self.timeKey, timeText)) }
        if keep != loaded.keep { changes.append((Self.keepKey, String(keep))) }
        return changes
    }

    var canSave: Bool {
        hasValues && !isBusy && !hasConflict && validator != nil && Self.keepRange.contains(keep) && !changedKeys.isEmpty
    }

    /// Reads the current values and the version that guards the next write. Also how a conflict is cleared.
    func open(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let (values, tag) = try await client.effectiveSettings()
            guard let tag, !tag.isEmpty else {
                hasValues = false
                errorMessage = String(localized: "The server did not send a version for its settings, so backup settings cannot be changed safely. Update the server, then try again")
                return
            }
            validator = tag
            isEnabled = (values[Self.enabledKey] ?? "true").lowercased() == "true"
            minutes = Self.minutes(from: values[Self.timeKey]) ?? 4 * 60
            keep = min(Self.keepRange.upperBound, max(Self.keepRange.lowerBound, Int(values[Self.keepKey] ?? "") ?? 7))
            loaded = (isEnabled, minutes, keep)
            hasValues = true
            hasConflict = false
            errorMessage = nil
        } catch {
            errorMessage = ErrorMessage.text(
                for: error, sessionState: sessionState, fallback: String(localized: "Could not load the backup settings.")
            )
        }
    }

    /// Returns true when every changed value was saved.
    func save(client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        guard canSave, var current = validator else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let changes = changedKeys
        for (index, change) in changes.enumerated() {
            do {
                let receipt = try await client.updateSetting(key: change.key, value: change.value, validator: current)
                if receipt.restartRequired { restartRequired = true }
            } catch let error as APIError where error.statusCode == 412 || error.statusCode == 428 {
                hasConflict = true
                errorMessage = String(localized: "These settings changed on the server after you opened them. Reload the current values, then make your change again.")
                return false
            } catch {
                errorMessage = ErrorMessage.text(
                    for: error, sessionState: sessionState, fallback: String(localized: "Could not save the backup settings.")
                )
                if index > 0 {
                    errorMessage = (errorMessage ?? "") + " " + String(localized: "Earlier changes were saved.")
                }
                return false
            }
            guard index + 1 < changes.count else { break }
            // The write changed the snapshot, so the next one needs the version that follows it.
            do {
                let (_, tag) = try await client.effectiveSettings()
                guard let tag, !tag.isEmpty else {
                    errorMessage = String(localized: "The server did not send a version for its settings. Earlier changes were saved. Reload the values to continue")
                    hasConflict = true
                    return false
                }
                current = tag
            } catch {
                errorMessage = ErrorMessage.text(
                    for: error, sessionState: sessionState, fallback: String(localized: "Could not save the backup settings.")
                ) + " " + String(localized: "Earlier changes were saved.")
                hasConflict = true
                return false
            }
        }
        return true
    }

    private static func minutes(from text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}
