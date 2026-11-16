import Foundation

/// Reads the server's RFC 3339 instants, with or without fractional seconds.
enum AdminTimestamp {
    static func date(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// "Nov 15, 2026 at 10:00" in the person's own time zone and language.
    static func displayText(_ text: String?, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let date = date(from: text) else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone)
        return date.formatted(style)
    }
}

/// A span of time as the Scheduled tasks page shows it: "850 ms", "5 s", "2 min 5 s", "1 h 5 min".
enum AdminDuration {
    static func text(milliseconds: Int) -> String {
        let ms = max(0, milliseconds)
        if ms < 1000 { return String(localized: "\(ms) ms") }
        let totalSeconds = ms / 1000
        if totalSeconds < 60 { return String(localized: "\(totalSeconds) s") }
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            let seconds = totalSeconds % 60
            return seconds == 0
                ? String(localized: "\(totalMinutes) min")
                : String(localized: "\(totalMinutes) min \(seconds) s")
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0
            ? String(localized: "\(hours) h")
            : String(localized: "\(hours) h \(minutes) min")
    }
}

/// One step of a task run, as `last_execution` and the run history list them.
struct TaskStep: Decodable, Equatable, Sendable {
    let key: String
    let name: String
    let status: String

    var isFailed: Bool { status == "failed" }
}

/// One finished run of a task: `last_execution` on `GET /api/v2/admin/tasks` and each item of
/// `GET /api/v2/admin/tasks/{key}/history`. `last_execution` carries no `id`, so the start time
/// stands in for it.
struct TaskExecution: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let status: String
    let startedAt: String
    let completedAt: String
    let durationMs: Int
    let errorMessage: String?
    let steps: [TaskStep]

    var failedSteps: [TaskStep] { steps.filter(\.isFailed) }
    var isFailed: Bool { status == "failed" }

    /// "Completed", "Failed", "Cancelled": the status in words.
    var statusText: String {
        switch status {
        case "completed": String(localized: "Completed")
        case "failed": String(localized: "Failed")
        case "cancelled": String(localized: "Cancelled")
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, status, steps
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationMs = "duration_ms"
        case errorMessage = "error_message"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let started = try container.decode(String.self, forKey: .startedAt)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? started
        status = try container.decode(String.self, forKey: .status)
        startedAt = started
        completedAt = try container.decode(String.self, forKey: .completedAt)
        durationMs = try container.decode(Int.self, forKey: .durationMs)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        steps = try container.decodeIfPresent([TaskStep].self, forKey: .steps) ?? []
    }

    init(
        id: String, status: String, startedAt: String, completedAt: String, durationMs: Int,
        errorMessage: String? = nil, steps: [TaskStep] = []
    ) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
        self.errorMessage = errorMessage
        self.steps = steps
    }
}
