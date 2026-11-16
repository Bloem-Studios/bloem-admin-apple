import Foundation

struct BackupActive: Decodable, Equatable, Sendable {
    /// `backup`, `delete`, `restore` or `upload`.
    let operation: String
    /// 0 to 100.
    let progress: Double
    let message: String?
    let uploadId: String?

    enum CodingKeys: String, CodingKey {
        case operation, progress, message
        case uploadId = "upload_id"
    }
}

struct BackupRun: Decodable, Equatable, Sendable {
    let status: String
    let startedAt: String
    let finishedAt: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, error
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

struct BackupWarning: Decodable, Equatable, Sendable {
    let code: String
    let message: String
}

/// One saved backup of `GET /api/v2/admin/backups`.
struct SavedBackup: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let status: String
    let createdAt: String
    let sizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case id, kind, status
        case createdAt = "created_at"
        case sizeBytes = "size_bytes"
    }
}

/// `GET /api/v2/admin/backups`: the schedule, what is running, the last run and the saved backups.
struct BackupsOverview: Decodable, Equatable, Sendable {
    let active: BackupActive?
    /// Another backup, delete, upload or restore holds the backup lock.
    let busy: Bool
    let destinationAvailable: Bool
    let enabled: Bool
    let items: [SavedBackup]
    let keep: Int
    let lastRun: BackupRun?
    let lastSuccessAt: String?
    let warnings: [BackupWarning]

    enum CodingKeys: String, CodingKey {
        case active, busy, enabled, items, keep, warnings
        case destinationAvailable = "destination_available"
        case lastRun = "last_run"
        case lastSuccessAt = "last_success_at"
    }
}

/// What the Backups page reads: the overview, and the backup task's next run (nil when the task cannot
/// be read, which leaves the overview as it is).
struct BackupsPage: Equatable, Sendable {
    let overview: BackupsOverview
    let taskNextRunAt: String?
    /// The nightly time (`HH:MM`, on the server's clock) from the backup task's daily trigger.
    var taskTimeOfDay: String? = nil
}

struct BackupRowPresentation: Equatable, Identifiable {
    let id: String
    let kindText: String
    let statusText: String
    /// How the status word is said: a backup that did not finish or cannot be read in the failure colour with a dot, one
    /// with warnings or not yet checked in the warning colour with a dot, the rest quietly.
    let statusTone: StatusLabel.Tone
    let sizeText: String
    let createdText: String
    let canDelete: Bool
}

struct BackupWarningLine: Equatable {
    let text: String
    /// Information rather than a problem.
    let isInformation: Bool
}

/// What the Backups page says. The clock is injected; the next run is only ever the server's own answer.
struct BackupsPresentation: Equatable {
    let lastSuccess: String
    let nextRun: String
    let activeText: String?
    let activeProgress: Double?
    let activeMessage: String?
    /// A last run that did not complete cleanly, with its error; nil when it did.
    let lastRun: String?
    let lastRunFailed: Bool
    let warnings: [BackupWarningLine]
    /// Why Back up now cannot run, or nil.
    let backUpNowBlocker: String?
    let rows: [BackupRowPresentation]

    init(overview: BackupsOverview, taskNextRunAt: String?, now: Date, locale: Locale = .current) {
        if let success = AdminTimestamp.date(from: overview.lastSuccessAt) {
            lastSuccess = String(localized: "Last successful backup \(formatRelativeTime(success, now: now))")
        } else {
            lastSuccess = String(localized: "No successful backup yet")
        }

        if !overview.enabled {
            nextRun = String(localized: "Nightly backups are off")
        } else if let next = AdminTimestamp.date(from: taskNextRunAt), next > now {
            nextRun = Self.nextText(secondsAhead: next.timeIntervalSince(now))
        } else {
            // The server reads backup.time on its own clock, so a missing or past time is not guessed.
            nextRun = String(localized: "Next backup time is not known yet")
        }

        if let active = overview.active {
            let percent = Int(min(100, max(0, active.progress)).rounded())
            switch active.operation {
            case "backup": activeText = String(localized: "Backup running, \(percent)%")
            case "delete": activeText = String(localized: "Deleting a backup, \(percent)%")
            case "restore": activeText = String(localized: "Restore running, \(percent)%")
            case "upload": activeText = String(localized: "Upload running, \(percent)%")
            default: activeText = String(localized: "Working, \(percent)%")
            }
            activeProgress = min(100, max(0, active.progress)) / 100
            activeMessage = active.message.flatMap { $0.isEmpty ? nil : $0 }
        } else {
            activeText = nil
            activeProgress = nil
            activeMessage = nil
        }

        if let run = overview.lastRun, run.status != "complete" {
            let when = AdminTimestamp.date(from: run.finishedAt ?? run.startedAt).map { formatRelativeTime($0, now: now) }
            let detail = run.error.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
            switch run.status {
            case "failed":
                lastRun = String(localized: "Last run failed \(when ?? "earlier")") + detail
            case "interrupted":
                lastRun = String(localized: "Last run was interrupted \(when ?? "earlier")") + detail
            case "complete_with_warnings":
                lastRun = String(localized: "Last run finished with warnings \(when ?? "earlier")") + detail
            default:
                lastRun = nil
            }
            lastRunFailed = run.status == "failed" || run.status == "interrupted"
        } else {
            lastRun = nil
            lastRunFailed = false
        }

        let backingUp = overview.active?.operation == "backup"
        let neverBackedUp = overview.lastSuccessAt == nil
        warnings = overview.warnings
            .filter { $0.code != "disabled" && !((backingUp || neverBackedUp) && $0.code == "no_recent_backup") }
            .map { warning in
                BackupWarningLine(
                    text: warning.code == "key_not_confirmed"
                        ? String(localized: "The encryption key has not been confirmed. Confirm it on the web")
                        : warning.message,
                    isInformation: warning.code == "no_backups_at_destination"
                )
            }

        let lock = Self.lockBlocker(overview)
        if let sqlite = overview.warnings.first(where: { $0.code == "sqlite_user_store" }) {
            backUpNowBlocker = sqlite.message
        } else if overview.warnings.contains(where: { $0.code == "key_not_confirmed" }) {
            backUpNowBlocker = String(localized: "Confirm the encryption key on the web before backing up")
        } else if let lock {
            backUpNowBlocker = lock
        } else if !overview.destinationAvailable {
            backUpNowBlocker = String(localized: "The backup destination cannot be reached")
        } else {
            backUpNowBlocker = nil
        }

        let locked = lock != nil
        rows = overview.items.map { backup in
            BackupRowPresentation(
                id: backup.id,
                kindText: Self.kindText(backup.kind),
                statusText: Self.statusText(backup.status),
                statusTone: Self.statusTone(backup.status),
                sizeText: Int64(backup.sizeBytes).formatted(.byteCount(style: .file).locale(locale)),
                createdText: AdminTimestamp.date(from: backup.createdAt)
                    .map { String(localized: "Created \(formatRelativeTime($0, now: now))") } ?? "",
                canDelete: !locked && backup.status != "in_progress"
            )
        }
    }

    /// Why a backup or a delete cannot start because the lock is held, or nil when it is free.
    static func lockBlocker(_ overview: BackupsOverview) -> String? {
        guard overview.busy || overview.active != nil else { return nil }
        switch overview.active?.operation {
        case "backup": return String(localized: "A backup is already running")
        case "delete": return String(localized: "A backup is being deleted")
        case "upload": return String(localized: "A backup upload is running")
        case "restore": return String(localized: "A restore is running")
        default: return String(localized: "Another backup task is running")
        }
    }

    private static func nextText(secondsAhead seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return String(localized: "Next backup in under a minute") }
        if minutes < 60 { return String(localized: "Next backup in \(minutes) min") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "Next backup in \(hours) h") }
        return String(localized: "Next backup in \(hours / 24) d")
    }

    private static func kindText(_ kind: String) -> String {
        switch kind {
        case "nightly": String(localized: "Nightly")
        case "manual": String(localized: "Manual")
        case "before-restore": String(localized: "Before restore")
        case "before-upgrade": String(localized: "Before upgrade")
        default: kind.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private static func statusTone(_ status: String) -> StatusLabel.Tone {
        switch status {
        case "incomplete", "unreadable": .failure
        case "complete_with_warnings", "unverified": .warning
        case "complete": .positive
        default: .normal
        }
    }

    private static func statusText(_ status: String) -> String {
        switch status {
        case "complete": String(localized: "Complete")
        case "complete_with_warnings": String(localized: "Complete with warnings")
        case "in_progress": String(localized: "In progress")
        case "incomplete": String(localized: "Incomplete")
        case "unverified": String(localized: "Unverified")
        case "unreadable": String(localized: "Unreadable")
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
