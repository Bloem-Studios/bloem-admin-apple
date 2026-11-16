import Foundation

/// A daily or weekly trigger as the schedule form edits it: a time of day, for weekly a weekday, and
/// an optional longest run in minutes. The web's trigger form offers the same fields.
struct TimedTriggerDraft: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case daily, weekly
    }

    /// What was edited, without the row's identity: two drafts with the same content are the same edit.
    struct Content: Equatable, Sendable {
        var kind: Kind
        var minutes: Int?
        var weekday: Int
        var maxRuntimeText: String
    }

    let id: UUID
    var kind: Kind
    /// Minutes after midnight; nil when the server's time could not be read as `HH:MM`.
    var minutes: Int?
    /// 0 is Sunday, as the server numbers them.
    var weekday: Int
    /// The longest run in minutes; empty means no limit.
    var maxRuntimeText: String
    /// Position among the daily and weekly triggers the schedule had when it was opened; nil for a new row.
    var sourceIndex: Int?

    var content: Content { Content(kind: kind, minutes: minutes, weekday: weekday, maxRuntimeText: maxRuntimeText) }

    init(kind: Kind, minutes: Int? = 9 * 60, weekday: Int = 1, maxRuntimeText: String = "", sourceIndex: Int? = nil) {
        id = UUID()
        self.kind = kind
        self.minutes = minutes
        self.weekday = weekday
        self.maxRuntimeText = maxRuntimeText
        self.sourceIndex = sourceIndex
    }

    /// The draft for a daily or weekly trigger read from the server; nil for any other type.
    init?(trigger: TaskTrigger, sourceIndex: Int) {
        guard let kind = Kind(rawValue: trigger.type) else { return nil }
        self.init(
            kind: kind,
            minutes: Self.minutes(from: trigger.timeOfDay),
            weekday: min(6, max(0, trigger.dayOfWeek ?? 0)),
            maxRuntimeText: Self.runtimeText(milliseconds: trigger.maxRuntimeMs),
            sourceIndex: sourceIndex
        )
    }

    /// "02:00"; empty when there is no readable time.
    var timeText: String {
        guard let minutes else { return "" }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Why this row cannot be saved, in words; nil when it can.
    var validationMessage: String? {
        if minutes == nil { return String(localized: "Choose a time of day.") }
        if case .failure = Self.parseRuntime(maxRuntimeText) {
            return String(localized: "Enter the longest run in minutes, or leave it empty for no limit.")
        }
        return nil
    }

    /// The trigger to send; nil while the row is invalid.
    func trigger() -> TaskTrigger? {
        guard minutes != nil, case .success(let maxRuntime) = Self.parseRuntime(maxRuntimeText) else { return nil }
        return TaskTrigger(
            type: kind.rawValue,
            timeOfDay: timeText,
            dayOfWeek: kind == .weekly ? weekday : nil,
            maxRuntimeMs: maxRuntime
        )
    }

    /// Sunday first, to match the server's numbering.
    static func weekdayNames(calendar: Calendar = .current, locale: Locale = .current) -> [String] {
        var localized = calendar
        localized.locale = locale
        return localized.weekdaySymbols
    }

    private static func minutes(from timeOfDay: String?) -> Int? {
        guard let timeOfDay else { return nil }
        let parts = timeOfDay.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    private static func runtimeText(milliseconds: Int?) -> String {
        guard let milliseconds, milliseconds > 0 else { return "" }
        if milliseconds % 60_000 == 0 { return String(milliseconds / 60_000) }
        return String(format: "%g", Double(milliseconds) / 60_000)
    }

    /// Empty is no limit (nil); otherwise minutes, fractions allowed as on the web, up to a year.
    private static func parseRuntime(_ text: String) -> Result<Int?, ScheduleInputError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return .success(nil) }
        guard let minutes = Double(trimmed), minutes.isFinite, minutes >= 0,
              minutes <= Double(ScheduleIntervalInput.maximumMinutes) else { return .failure(.notANumber) }
        let milliseconds = Int((minutes * 60_000).rounded())
        return .success(milliseconds > 0 ? milliseconds : nil)
    }
}

extension AdminTask {
    /// The backup task's time is the `backup.time` setting; the server rewrites any trigger edited here.
    var followsBackupSetting: Bool { key == "backup" }
}

extension TaskTrigger {
    var isTimed: Bool { TimedTriggerDraft.Kind(rawValue: type) != nil }
}
