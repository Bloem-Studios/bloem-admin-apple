import Foundation

/// What one Scheduled tasks row says and offers, worked out from the fields `GET /api/v2/admin/tasks`
/// already returns (`state`, `progress`, `last_execution`, `next_run_at`). Status is stated in words;
/// the clock is injected so Overdue is testable.
struct TaskRowPresentation: Equatable {
    let stateText: String
    let isRunning: Bool
    /// 0...1 while running and the server has reported progress; nil when idle or not yet reported.
    let progress: Double?
    let lastResult: String
    let lastResultFailed: Bool
    /// "Next run in 2 h" or "Overdue"; nil while running, stopping, or with no next run.
    let nextRun: String?
    let isOverdue: Bool
    /// Run is offered only while the task is idle.
    let canRun: Bool
    /// Cancel is offered only while it runs (not again while it is already stopping).
    let canCancel: Bool

    init(task: AdminTask, now: Date) {
        isRunning = task.state == "running"
        canRun = task.state == "idle"
        canCancel = task.state == "running"

        let percent = min(100, max(0, task.progress.isFinite ? task.progress : 0))
        switch task.state {
        case "idle":
            stateText = String(localized: "Idle")
            progress = nil
        case "running":
            progress = percent > 0 ? percent / 100 : nil
            stateText = percent > 0
                ? String(localized: "Running, \(Self.percentText(percent))")
                : String(localized: "Running")
        case "cancelling":
            stateText = String(localized: "Stopping")
            progress = percent > 0 ? percent / 100 : nil
        default:
            stateText = task.state.capitalized
            progress = nil
        }

        if let last = task.lastExecution {
            let age = AdminTimestamp.date(from: last.completedAt).map { formatRelativeTime($0, now: now) }
            let took = AdminDuration.text(milliseconds: last.durationMs)
            lastResult = age.map { String(localized: "\(last.statusText) \($0), took \(took)") }
                ?? String(localized: "\(last.statusText), took \(took)")
            lastResultFailed = last.isFailed
        } else {
            lastResult = String(localized: "Never run")
            lastResultFailed = false
        }

        if task.state == "idle", let next = AdminTimestamp.date(from: task.nextRunAt) {
            let seconds = next.timeIntervalSince(now)
            if seconds < 0 {
                nextRun = String(localized: "Overdue")
                isOverdue = true
            } else {
                nextRun = Self.nextRunText(secondsAhead: seconds)
                isOverdue = false
            }
        } else {
            nextRun = nil
            isOverdue = false
        }
    }

    private static func nextRunText(secondsAhead seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return String(localized: "Next run in under a minute") }
        if minutes < 60 { return String(localized: "Next run in \(minutes) min") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "Next run in \(hours) h") }
        return String(localized: "Next run in \(hours / 24) d")
    }

    private static func percentText(_ percent: Double) -> String {
        if percent == percent.rounded() { return "\(Int(percent))%" }
        // A task still running reports just under 100 on purpose; rounding must not read as finished.
        let shown = (percent * 10).rounded() / 10
        return "\(min(shown, 99.9))%"
    }
}

extension TaskTrigger {
    /// The schedule in words: "Every 3 hours", "Every day at 02:00", "Every Sunday at 03:30",
    /// "When the server starts", with the maximum runtime appended when one is set. Several triggers
    /// are joined with a semicolon.
    static func words(for triggers: [TaskTrigger], calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard !triggers.isEmpty else { return String(localized: "Not scheduled") }
        return triggers.map { $0.words(calendar: calendar, locale: locale) }.joined(separator: "; ")
    }

    func words(calendar: Calendar = .current, locale: Locale = .current) -> String {
        var text: String
        switch type {
        case Self.startupType:
            text = String(localized: "When the server starts")
        case Self.intervalType:
            text = Self.everyText(milliseconds: intervalMs ?? 0)
        case "daily":
            text = String(localized: "Every day at \(timeOfDay ?? "00:00")")
        case "weekly":
            var localized = calendar
            localized.locale = locale
            let names = localized.weekdaySymbols
            let day = dayOfWeek ?? 0
            let name = names.indices.contains(day) ? names[day] : String(day)
            text = String(localized: "Every \(name) at \(timeOfDay ?? "00:00")")
        default:
            text = type.capitalized
        }
        if let maxRuntimeMs, maxRuntimeMs > 0 {
            text += String(localized: ", stops after \(Self.spanText(milliseconds: maxRuntimeMs))")
        }
        return text
    }

    private enum Unit { case days, hours, minutes, seconds }

    private static func split(milliseconds ms: Int) -> (count: Int, unit: Unit) {
        if ms >= 86_400_000, ms % 86_400_000 == 0 { return (ms / 86_400_000, .days) }
        if ms >= 3_600_000, ms % 3_600_000 == 0 { return (ms / 3_600_000, .hours) }
        if ms >= 60_000, ms % 60_000 == 0 { return (ms / 60_000, .minutes) }
        return (max(1, Int((Double(ms) / 1000).rounded())), .seconds)
    }

    private static func everyText(milliseconds: Int) -> String {
        let (count, unit) = split(milliseconds: milliseconds)
        switch (unit, count) {
        case (.days, 1): return String(localized: "Every day")
        case (.hours, 1): return String(localized: "Every hour")
        case (.minutes, 1): return String(localized: "Every minute")
        case (.seconds, 1): return String(localized: "Every second")
        case (.days, _): return String(localized: "Every \(count) days")
        case (.hours, _): return String(localized: "Every \(count) hours")
        case (.minutes, _): return String(localized: "Every \(count) minutes")
        case (.seconds, _): return String(localized: "Every \(count) seconds")
        }
    }

    private static func spanText(milliseconds: Int) -> String {
        let (count, unit) = split(milliseconds: milliseconds)
        switch (unit, count) {
        case (.days, 1): return String(localized: "1 day")
        case (.hours, 1): return String(localized: "1 hour")
        case (.minutes, 1): return String(localized: "1 minute")
        case (.seconds, 1): return String(localized: "1 second")
        case (.days, _): return String(localized: "\(count) days")
        case (.hours, _): return String(localized: "\(count) hours")
        case (.minutes, _): return String(localized: "\(count) minutes")
        case (.seconds, _): return String(localized: "\(count) seconds")
        }
    }
}
