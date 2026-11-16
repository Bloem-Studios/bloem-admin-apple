import Foundation

// What the Libraries page reads. Field names and shapes follow the server's own source:
// `GET /api/v2/libraries` (internal/apiv2/libraries.go `Library`), `GET /api/v2/admin/autoscan/scans`
// (admin_autoscan_scans.go), `POST /api/v2/libraries/{id}/check-mount` (`LibraryMountCheck`) and
// `GET /api/v2/admin/jobs` (admin_task_jobs.go `AdminTaskJob`). Timestamps decode leniently: one malformed
// instant leaves that field empty instead of losing the row.

private extension KeyedDecodingContainer {
    func lenientDate(_ key: Key) -> Date? {
        (try? decodeIfPresent(Date.self, forKey: key)) ?? nil
    }

    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    func optional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// "paused_for_review" and "task:scan" read as "Paused for review" and "Task scan".
func sentenceCased(_ serverWord: String) -> String {
    let words = serverWord.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ":", with: " ")
        .trimmingCharacters(in: .whitespaces)
    guard let first = words.first else { return serverWord }
    return first.uppercased() + words.dropFirst()
}

// MARK: - Library

/// One row of `GET /api/v2/libraries`.
struct AdminLibrary: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var type: String
    var paths: [String]
    var enabled: Bool
    var lastScannedAt: Date?
    var scanWarning: LibraryScanWarning?

    var pathCount: Int { paths.count }
}

extension AdminLibrary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, type, paths, enabled
        case lastScannedAt = "last_scanned_at"
        case warningCode = "scan_warning_code"
        case warningMessage = "scan_warning_message"
        case warningAt = "scan_warning_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.value(.name, default: "")
        type = c.value(.type, default: "")
        paths = c.value(.paths, default: [])
        enabled = c.value(.enabled, default: true)
        lastScannedAt = c.lenientDate(.lastScannedAt)
        if let code: String = c.optional(.warningCode), !code.isEmpty {
            scanWarning = LibraryScanWarning(code: code, message: c.optional(.warningMessage), raisedAt: c.lenientDate(.warningAt))
        } else {
            scanWarning = nil
        }
    }
}

/// `scan_warning_code`, `scan_warning_message` and `scan_warning_at`: an empty or dead root, for example.
struct LibraryScanWarning: Equatable, Sendable {
    let code: String
    let message: String?
    let raisedAt: Date?

    /// What happened, in plain words; the server's own message goes under it.
    var headline: String {
        switch code {
        case "empty_root": String(localized: "The scan found no media files")
        case "dead_root": String(localized: "A library folder cannot be reached")
        default: sentenceCased(code)
        }
    }
}

// MARK: - Scan runs

enum ScanRunStatus: Equatable, Sendable {
    case queued, running, completed, failed, stopped
    case other(String)

    init(serverValue: String) {
        switch serverValue {
        case "accepted": self = .queued
        case "running": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled", "canceled": self = .stopped
        default: self = .other(serverValue)
        }
    }

    var label: String {
        switch self {
        case .queued: String(localized: "Queued")
        case .running: String(localized: "Running")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .stopped: String(localized: "Stopped")
        case .other(let value): sentenceCased(value)
        }
    }

    var isActive: Bool { self == .queued || self == .running }
}

/// The counters of a finished run (`AdminAutoscanScanResult`).
struct ScanRunResult: Equatable, Sendable {
    var new = 0
    var updated = 0
    var unchanged = 0
    var missing = 0
    var errors = 0
    var skipped = 0
}

extension ScanRunResult: Decodable {
    private enum CodingKeys: String, CodingKey { case new, updated, unchanged, missing, errors, skipped }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        new = c.value(.new, default: 0)
        updated = c.value(.updated, default: 0)
        unchanged = c.value(.unchanged, default: 0)
        missing = c.value(.missing, default: 0)
        errors = c.value(.errors, default: 0)
        skipped = c.value(.skipped, default: 0)
    }
}

/// One row of `GET /api/v2/admin/autoscan/scans`: every scan run, manual, scheduled or autoscan.
struct ScanRun: Identifiable, Equatable, Sendable {
    let id: String
    let libraryID: String
    let mode: String
    let path: String?
    let trigger: String
    let status: ScanRunStatus
    let errorMessage: String?
    let requestedAt: Date?
    let startedAt: Date?
    let completedAt: Date?
    let result: ScanRunResult?

    /// Time from start to finish; nil until the run has both.
    var duration: TimeInterval? {
        guard let startedAt, let completedAt else { return nil }
        return max(0, completedAt.timeIntervalSince(startedAt))
    }

    /// When the run last changed, for picking the latest of several.
    var latestActivity: Date { completedAt ?? startedAt ?? requestedAt ?? .distantPast }

    /// Where the scan came from, in the web's words.
    var triggerLabel: String {
        switch trigger {
        case "autoscan": String(localized: "Autoscan")
        case "library_created": String(localized: "Created")
        case "library_paths_changed", "library_updated": String(localized: "Updated")
        case "library_id", "manual": String(localized: "Manual")
        case "task:scan_libraries", "task_scan_libraries": String(localized: "Scheduled")
        case "realtime_monitor": String(localized: "File change")
        default: sentenceCased(trigger)
        }
    }
}

extension ScanRun: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, mode, path, trigger, status, result
        case libraryID = "library_id"
        case errorMessage = "error_message"
        case requestedAt = "requested_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        libraryID = try c.decode(String.self, forKey: .libraryID)
        mode = c.value(.mode, default: "library")
        let rawPath: String? = c.optional(.path)
        path = rawPath?.isEmpty == false ? rawPath : nil
        trigger = c.value(.trigger, default: "")
        status = ScanRunStatus(serverValue: c.value(.status, default: ""))
        let rawError: String? = c.optional(.errorMessage)
        errorMessage = rawError?.isEmpty == false ? rawError : nil
        requestedAt = c.lenientDate(.requestedAt)
        startedAt = c.lenientDate(.startedAt)
        completedAt = c.lenientDate(.completedAt)
        result = c.optional(.result)
    }
}

// MARK: - Mount check

/// The answer of `POST /api/v2/libraries/{id}/check-mount`.
struct MountCheck: Equatable, Sendable {
    struct Root: Equatable, Sendable {
        let path: String
        let reachable: Bool
        let errorCode: String?
        let errorMessage: String?
        let suspectEmpty: Bool
    }

    enum Verdict: Equatable, Sendable {
        case reachable, unreachable, looksEmpty

        var headline: String {
            switch self {
            case .reachable: String(localized: "The mount is reachable")
            case .unreachable: String(localized: "The mount cannot be reached")
            case .looksEmpty: String(localized: "The mount is reachable but looks empty")
            }
        }
    }

    let libraryID: String
    let libraryName: String
    let healthy: Bool
    let checkedAt: Date?
    let summary: String
    let roots: [Root]

    var verdict: Verdict {
        if roots.contains(where: { !$0.reachable }) { return .unreachable }
        if roots.contains(where: \.suspectEmpty) { return .looksEmpty }
        return healthy ? .reachable : .unreachable
    }

    /// The roots that are not fine, for listing under the answer.
    var problemRoots: [Root] { roots.filter { !$0.reachable || $0.suspectEmpty } }
}

extension MountCheck.Root: Decodable {
    private enum CodingKeys: String, CodingKey {
        case path, reachable
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case suspectEmpty = "suspect_empty"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.value(.path, default: "")
        reachable = c.value(.reachable, default: false)
        errorCode = c.optional(.errorCode)
        errorMessage = c.optional(.errorMessage)
        suspectEmpty = c.value(.suspectEmpty, default: false)
    }
}

extension MountCheck: Decodable {
    private enum CodingKeys: String, CodingKey {
        case healthy, summary, roots
        case libraryID = "library_id"
        case libraryName = "library_name"
        case checkedAt = "checked_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraryID = c.value(.libraryID, default: "")
        libraryName = c.value(.libraryName, default: "")
        healthy = c.value(.healthy, default: false)
        checkedAt = c.lenientDate(.checkedAt)
        summary = c.value(.summary, default: "")
        roots = c.value(.roots, default: [])
    }
}

// MARK: - Metadata refresh jobs

/// The two ways to refresh a library's metadata (`POST /api/v2/libraries/{id}/refresh-metadata`, body `mode`).
enum LibraryRefreshMode: Sendable {
    /// `quick`: matched items never refreshed, missing an overview or artwork, or that failed a refresh.
    case missingOnly
    /// `full`: every item again.
    case all

    var serverValue: String {
        switch self {
        case .missingOnly: "quick"
        case .all: "full"
        }
    }
}

enum RefreshJobState: Equatable, Sendable {
    case queued, running, canceling, completed, failed, canceled
    case other(String)

    init(serverValue: String) {
        switch serverValue {
        case "queued": self = .queued
        case "running": self = .running
        case "canceling": self = .canceling
        case "succeeded": self = .completed
        case "failed": self = .failed
        case "canceled": self = .canceled
        default: self = .other(serverValue)
        }
    }

    var label: String {
        switch self {
        case .queued: String(localized: "Queued")
        case .running: String(localized: "Running")
        case .canceling: String(localized: "Canceling")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .canceled: String(localized: "Canceled")
        case .other(let value): sentenceCased(value)
        }
    }
}

/// A retained library metadata refresh: a row of `GET /api/v2/admin/jobs?kind=library_refresh`, or the job
/// `refresh-metadata` answers with (which does not name the library, so the caller fills it in).
struct LibraryRefreshJob: Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let state: RefreshJobState
    let terminal: Bool
    let cancelable: Bool
    let createdAt: Date?
    let finishedAt: Date?
    var libraryID: String?
    var libraryName: String?
    let progress: (current: Int, total: Int, unit: String)?
    let refreshed: Int?
    let failed: Int?

    static func == (lhs: LibraryRefreshJob, rhs: LibraryRefreshJob) -> Bool {
        lhs.id == rhs.id && lhs.state == rhs.state && lhs.terminal == rhs.terminal && lhs.cancelable == rhs.cancelable
            && lhs.libraryID == rhs.libraryID && lhs.libraryName == rhs.libraryName && lhs.createdAt == rhs.createdAt
            && lhs.finishedAt == rhs.finishedAt && lhs.progress?.current == rhs.progress?.current
            && lhs.progress?.total == rhs.progress?.total && lhs.refreshed == rhs.refreshed && lhs.failed == rhs.failed
    }

    var isActive: Bool { !terminal }

    /// "40 of 200 items" while it runs.
    var progressText: String? {
        guard let progress, progress.total > 0 else { return nil }
        return String(localized: "\(progress.current) of \(progress.total) \(progress.unit)")
    }

    /// "197 refreshed, 3 failed" once it has finished.
    var resultText: String? {
        guard let refreshed else { return nil }
        guard let failed, failed > 0 else { return String(localized: "\(refreshed) refreshed") }
        return String(localized: "\(refreshed) refreshed, \(failed) failed")
    }

    func naming(libraryID: String, libraryName: String) -> LibraryRefreshJob {
        var copy = self
        copy.libraryID = libraryID
        copy.libraryName = libraryName
        return copy
    }
}

extension LibraryRefreshJob: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, state, terminal, cancelable, progress
        case createdAt = "created_at"
        case finishedAt = "finished_at"
        case refreshResult = "refresh_result"
        case libraryID = "library_id"
        case libraryName = "library_name"
    }

    private struct Progress: Decodable {
        let current: Int
        let total: Int
        let unit: String?
    }

    private struct RefreshResult: Decodable {
        let refreshed: Int
        let failed: Int
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.value(.kind, default: "")
        state = RefreshJobState(serverValue: c.value(.state, default: ""))
        terminal = c.value(.terminal, default: false)
        cancelable = c.value(.cancelable, default: false)
        createdAt = c.lenientDate(.createdAt)
        finishedAt = c.lenientDate(.finishedAt)
        let rawID: String? = c.optional(.libraryID)
        libraryID = rawID?.isEmpty == false ? rawID : nil
        libraryName = c.optional(.libraryName)
        if let value: Progress = c.optional(.progress) {
            progress = (value.current, value.total, value.unit ?? String(localized: "items"))
        } else {
            progress = nil
        }
        let result: RefreshResult? = c.optional(.refreshResult)
        refreshed = result?.refreshed
        failed = result?.failed
    }
}

// MARK: - Page state

/// What a library row says about its scans: Queued, Running, then how the last one ended.
enum LibraryScanState: Equatable, Sendable {
    case idle
    case queued(count: Int)
    /// `count` running now, `queued` more waiting.
    case running(count: Int, queued: Int)
    case finished(ScanRun)

    /// `active` is every queued and running run; `recent` the latest runs of any state. `pending` is a scan the
    /// server accepted that its list does not show yet.
    static func resolve(libraryID: String, active: [ScanRun], recent: [ScanRun], pending: Bool) -> LibraryScanState {
        let mine = active.filter { $0.libraryID == libraryID && $0.status.isActive }
        let running = mine.filter { $0.status == .running }.count
        let queued = mine.count - running
        if running > 0 { return .running(count: running, queued: queued) }
        if queued > 0 { return .queued(count: queued) }
        if pending { return .queued(count: 1) }
        let finished = recent.filter { $0.libraryID == libraryID && !$0.status.isActive }
        if let latest = finished.max(by: { $0.latestActivity < $1.latestActivity }) { return .finished(latest) }
        return .idle
    }

    var label: String? {
        switch self {
        case .idle: nil
        case .queued: ScanRunStatus.queued.label
        case .running: ScanRunStatus.running.label
        case .finished(let run): run.status.label
        }
    }

    /// Why a run failed, when the server said.
    var detail: String? {
        guard case .finished(let run) = self, run.status == .failed else { return nil }
        return run.errorMessage
    }

    var isActive: Bool {
        switch self {
        case .queued, .running: true
        case .idle, .finished: false
        }
    }
}
