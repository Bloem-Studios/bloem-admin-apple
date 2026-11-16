import Foundation

struct AdminJobProgress: Decodable, Equatable, Sendable {
    let current: Int
    let total: Int
    let unit: String
}

struct AdminJobFailure: Decodable, Equatable, Sendable {
    let type: String
    let title: String
    let detail: String
    let retryable: Bool
}

/// One background job of `GET /api/v2/admin/jobs`: library refreshes and deletions, restores,
/// catalogue exports and the like. Only what the history list shows is decoded; the per-kind result
/// objects stay on the web.
struct AdminJob: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let state: String
    let terminal: Bool
    let cancelable: Bool
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
    let libraryName: String?
    let sourceLabel: String?
    let progress: AdminJobProgress?
    let failure: AdminJobFailure?

    enum CodingKeys: String, CodingKey {
        case id, kind, state, terminal, cancelable, progress, failure
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case libraryName = "library_name"
        case sourceLabel = "source_label"
    }
}

/// What one Job history row says. The clock is injected.
struct JobRowPresentation: Equatable {
    let title: String
    /// The library or source the job worked on, when it names one.
    let target: String?
    let stateText: String
    let isFailed: Bool
    /// "Finished 2 h ago", "Started 5 min ago" or "Queued 1 h ago".
    let when: String
    /// "Restore failed: Not enough space".
    let failure: String?
    /// 0...1 while the job reports progress and has not finished.
    let progress: Double?
    let progressText: String?

    init(job: AdminJob, now: Date) {
        title = Self.title(forKind: job.kind)
        target = [job.libraryName, job.sourceLabel].compactMap { $0 }.first { !$0.isEmpty }
        isFailed = job.state == "failed"
        switch job.state {
        case "queued": stateText = String(localized: "Queued")
        case "running": stateText = String(localized: "Running")
        case "completed": stateText = String(localized: "Completed")
        case "failed": stateText = String(localized: "Failed")
        case "cancelled": stateText = String(localized: "Cancelled")
        default: stateText = job.state.replacingOccurrences(of: "_", with: " ").capitalized
        }

        if let finished = AdminTimestamp.date(from: job.finishedAt) {
            when = String(localized: "Finished \(formatRelativeTime(finished, now: now))")
        } else if job.state == "running", let started = AdminTimestamp.date(from: job.startedAt) {
            when = String(localized: "Started \(formatRelativeTime(started, now: now))")
        } else if let created = AdminTimestamp.date(from: job.createdAt) {
            when = String(localized: "Queued \(formatRelativeTime(created, now: now))")
        } else {
            when = ""
        }

        if let failure = job.failure {
            self.failure = failure.detail.isEmpty ? failure.title : "\(failure.title): \(failure.detail)"
        } else {
            failure = nil
        }

        if let reported = job.progress, !job.terminal, reported.total > 0 {
            progress = min(1, max(0, Double(reported.current) / Double(reported.total)))
            progressText = reported.unit.isEmpty
                ? String(localized: "\(reported.current) of \(reported.total)")
                : String(localized: "\(reported.current) of \(reported.total) \(reported.unit)")
        } else {
            progress = nil
            progressText = nil
        }
    }

    /// The web's names for the job types it knows; any other kind reads as plain words, never hidden.
    static func title(forKind kind: String) -> String {
        switch kind {
        case "delete_library": return String(localized: "Library deletion")
        case "image_cache_cleanup": return String(localized: "Image cache cleanup")
        case "catalog_export": return String(localized: "Catalog export")
        case "catalog_import": return String(localized: "Catalog import")
        case "item_refresh": return String(localized: "Item refresh")
        case "library_refresh": return String(localized: "Library refresh")
        case "backup_restore": return String(localized: "Backup restore")
        case "storage_transition": return String(localized: "Storage transition")
        case "template_bundle_apply": return String(localized: "Template bundle apply")
        default:
            let words = kind.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}
