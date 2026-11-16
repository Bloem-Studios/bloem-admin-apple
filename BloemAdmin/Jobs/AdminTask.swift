import Foundation

enum ScheduleInputError: Error, Equatable {
    case empty
    case notANumber
    case notPositive
    case outOfRange

    var message: String {
        switch self {
        case .empty:
            return String(localized: "Enter an interval in minutes")
        case .notANumber:
            return String(localized: "Enter a whole number of minutes")
        case .notPositive:
            return String(localized: "The interval must be greater than zero")
        case .outOfRange:
            return String(localized: "Enter an interval of one year or less")
        }
    }
}

struct ScheduleIntervalInput {
    /// A one-year ceiling keeps schedules meaningful while also ensuring the
    /// conversion to milliseconds used by `TaskTrigger.interval` is safe.
    static let maximumMinutes = 525_600

    static func parse(_ input: String) -> Result<Int, ScheduleInputError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let minutes = Int(trimmed) else {
            return .failure(trimmed.allSatisfy(\.isNumber) ? .outOfRange : .notANumber)
        }
        guard minutes > 0 else { return .failure(.notPositive) }
        guard minutes <= maximumMinutes else { return .failure(.outOfRange) }
        return .success(minutes)
    }
}

struct PrivilegedMutationGate {
    private(set) var isActive = false

    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    mutating func end() {
        isActive = false
    }

    /// Acquires the gate before invoking `launch`, so a second UI event in
    /// the same run-loop turn cannot enqueue another unstructured task.
    @discardableResult
    mutating func submit(_ launch: () -> Void) -> Bool {
        guard begin() else { return false }
        launch()
        return true
    }
}

enum ScheduleEditorLoadIssue: Error, Equatable {
    case missingIntervalMilliseconds
    case invalidInterval
    case repeatedIntervals

    var message: String {
        switch self {
        case .missingIntervalMilliseconds:
            return String(localized: "This task has an interval trigger without a duration. Turn off Run on an interval to remove it.")
        case .invalidInterval:
            return String(localized: "This task has an interval that this editor cannot safely represent. Turn off Run on an interval to remove it.")
        case .repeatedIntervals:
            return String(localized: "This task has multiple interval triggers, which this editor cannot safely change. Turn off Run on an interval to remove them.")
        }
    }
}

struct ScheduleEditorState: Equatable {
    /// The value loaded from the server, kept separately from the live toggle
    /// so interval removal can only result from a real on-to-off transition.
    let intervalEnabled: Bool
    let intervalMinutesText: String
    let blockingIssue: ScheduleEditorLoadIssue?

    func makePayload(
        startupEnabled: Bool,
        intervalEnabled: Bool,
        intervalInput: String,
        triggers: [TaskTrigger]
    ) -> [TaskTrigger]? {
        if !intervalEnabled {
            // If triggers contain an interval but the loaded state says they
            // did not, refusing the payload is safer than inferring removal.
            guard self.intervalEnabled || !triggers.contains(where: \.isInterval) else { return nil }
            return TaskTrigger.applyingScheduleEditor(
                startupEnabled: startupEnabled,
                intervalMinutes: nil,
                to: triggers
            )
        }

        guard blockingIssue == nil else { return nil }
        guard case .success(let minutes) = ScheduleIntervalInput.parse(intervalInput) else { return nil }
        return TaskTrigger.applyingScheduleEditor(
            startupEnabled: startupEnabled,
            intervalMinutes: minutes,
            to: triggers
        )
    }
}

struct AdminTask: Decodable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let name: String
    let description: String
    let category: String
    let state: String
    let progress: Double
    let progressMessage: String?
    /// Manual-only tasks run only when started by hand and cannot be scheduled.
    let manualOnly: Bool
    let triggers: [TaskTrigger]
    /// The most recent finished run; absent for a task that never ran.
    var lastExecution: TaskExecution? = nil
    /// RFC 3339 instant of the next scheduled run; absent for a manual-only or unscheduled task.
    var nextRunAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case key, name, description, category, state, progress, triggers
        case progressMessage = "progress_message"
        case manualOnly = "manual_only"
        case lastExecution = "last_execution"
        case nextRunAt = "next_run_at"
    }
}

/// One entry in a task's trigger schedule, as accepted/returned by
/// `PUT /api/v2/admin/tasks/{key}/triggers` (wrapped as `{"triggers": [...]}`)
/// and returned by the task list and `GET .../triggers`. `type` is a string;
/// The server owns the trigger vocabulary. This app edits interval/startup
/// triggers but preserves every field on all trigger types during PUT
/// replacement round trips.
struct TaskTrigger: Codable, Equatable, Sendable {
    let type: String
    let intervalMs: Int?
    let timeOfDay: String?
    let dayOfWeek: Int?
    let maxRuntimeMs: Int?

    init(
        type: String,
        intervalMs: Int? = nil,
        timeOfDay: String? = nil,
        dayOfWeek: Int? = nil,
        maxRuntimeMs: Int? = nil
    ) {
        self.type = type
        self.intervalMs = intervalMs
        self.timeOfDay = timeOfDay
        self.dayOfWeek = dayOfWeek
        self.maxRuntimeMs = maxRuntimeMs
    }

    enum CodingKeys: String, CodingKey {
        case type
        case intervalMs = "interval_ms"
        case timeOfDay = "time_of_day"
        case dayOfWeek = "day_of_week"
        case maxRuntimeMs = "max_runtime_ms"
    }

    static let startupType = "startup"
    static let intervalType = "interval"

    static func interval(minutes: Int) -> TaskTrigger {
        TaskTrigger(type: intervalType, intervalMs: minutes * 60_000, timeOfDay: nil, dayOfWeek: nil, maxRuntimeMs: nil)
    }

    static let startup = TaskTrigger(type: startupType, intervalMs: nil, timeOfDay: nil, dayOfWeek: nil, maxRuntimeMs: nil)

    var isStartup: Bool { type == Self.startupType }
    var isInterval: Bool { type == Self.intervalType }
    /// `interval_ms` converted to whole minutes for the editable "run every
    /// N minutes" field. Rounds rather than truncates so an interval that
    /// isn't an exact multiple of a minute (unlikely from this app, but
    /// possible if set some other way) doesn't silently display as 0.
    var intervalMinutes: Int? {
        guard let intervalMs else { return nil }
        return Int((Double(intervalMs) / 60_000).rounded())
    }

    /// Short plain-language description for the schedule summary.
    var summary: String {
        switch type {
        case Self.startupType:
            return String(localized: "On server startup")
        case Self.intervalType:
            guard let minutes = intervalMinutes else { return String(localized: "On an interval") }
            return Self.everyText(minutes: minutes)
        case "daily":
            guard let timeOfDay else { return String(localized: "Daily") }
            return String(localized: "Daily at \(timeOfDay)")
        case "weekly":
            return String(localized: "Weekly")
        default:
            return type.capitalized
        }
    }

    /// "Every minute", "Every 15 minutes", "Every hour", "Every 6 hours", "Every day": never "Every 1440 minutes".
    static func everyText(minutes: Int) -> String {
        switch minutes {
        case 1: return String(localized: "Every minute")
        case 60: return String(localized: "Every hour")
        case 1440: return String(localized: "Every day")
        default:
            let length = Duration.seconds(minutes * 60).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
            return String(localized: "Every \(length)")
        }
    }

    static func scheduleEditorState(from triggers: [TaskTrigger]) -> ScheduleEditorState {
        let intervals = triggers.filter(\.isInterval)
        guard !intervals.isEmpty else {
            return ScheduleEditorState(intervalEnabled: false, intervalMinutesText: "", blockingIssue: nil)
        }
        guard intervals.count == 1 else {
            return ScheduleEditorState(intervalEnabled: true, intervalMinutesText: "", blockingIssue: .repeatedIntervals)
        }
        guard let milliseconds = intervals[0].intervalMs else {
            return ScheduleEditorState(intervalEnabled: true, intervalMinutesText: "", blockingIssue: .missingIntervalMilliseconds)
        }
        guard milliseconds > 0, milliseconds.isMultiple(of: 60_000) else {
            return ScheduleEditorState(intervalEnabled: true, intervalMinutesText: "", blockingIssue: .invalidInterval)
        }

        let minutes = milliseconds / 60_000
        guard case .success = ScheduleIntervalInput.parse(String(minutes)) else {
            return ScheduleEditorState(intervalEnabled: true, intervalMinutesText: "", blockingIssue: .invalidInterval)
        }
        return ScheduleEditorState(intervalEnabled: true, intervalMinutesText: String(minutes), blockingIssue: nil)
    }

    func replacingInterval(minutes: Int) -> TaskTrigger {
        TaskTrigger(
            type: type,
            intervalMs: minutes * 60_000,
            timeOfDay: timeOfDay,
            dayOfWeek: dayOfWeek,
            maxRuntimeMs: maxRuntimeMs
        )
    }

    static func applyingScheduleEditor(
        startupEnabled: Bool,
        intervalMinutes: Int?,
        to triggers: [TaskTrigger]
    ) -> [TaskTrigger] {
        var retainedStartup = false
        var retainedInterval = false
        var edited = triggers.compactMap { trigger -> TaskTrigger? in
            if trigger.isStartup {
                guard startupEnabled else { return nil }
                retainedStartup = true
                return trigger
            }
            if trigger.isInterval {
                guard let intervalMinutes, intervalMinutes > 0 else { return nil }
                retainedInterval = true
                return trigger.replacingInterval(minutes: intervalMinutes)
            }
            return trigger
        }
        if startupEnabled, !retainedStartup {
            edited.append(.startup)
        }
        if let intervalMinutes, intervalMinutes > 0, !retainedInterval {
            edited.append(.interval(minutes: intervalMinutes))
        }
        return edited
    }

}
