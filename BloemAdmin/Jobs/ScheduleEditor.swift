import Foundation
import Observation

/// A schedule as it was read when the editor opened, with the ETag that guards the save.
struct ScheduleSnapshot: Equatable, Sendable {
    let triggers: [TaskTrigger]
    let validator: String
}

/// State of one schedule edit; the same guarded approach as `SettingEditor`. The ETag read when
/// the editor opened is the one the save sends, and a save never re-reads first, so an edit made
/// elsewhere in between surfaces as a conflict (412, or 428 when the tag is missing) instead of
/// being overwritten. A conflict keeps the form as typed and lets the person review the current
/// schedule and then save over it deliberately. Triggers this editor cannot represent (daily,
/// weekly, extra runtime fields) are carried over unchanged.
@Observable
@MainActor
final class ScheduleEditor {
    let task: AdminTask
    /// Set in All Servers mode so the sheet and its errors name the server being edited.
    let serverName: String?
    var startupEnabled = false
    var intervalEnabled = false
    var intervalMinutesText = ""
    private(set) var snapshot: ScheduleSnapshot?
    /// The current server schedule, read after a conflict.
    private(set) var latest: ScheduleSnapshot?
    private(set) var hasConflict = false
    private(set) var errorMessage: String?
    private(set) var isBusy = false
    /// What the base schedule looked like, for deciding whether an interval may be removed.
    private var loadedState = ScheduleEditorState(intervalEnabled: false, intervalMinutesText: "", blockingIssue: nil)

    init(task: AdminTask, serverName: String? = nil) {
        self.task = task
        self.serverName = serverName
    }

    /// "<server> · <task>" in All Servers mode, otherwise just the task name.
    var title: String { serverName.map { "\($0) · \(task.name)" } ?? task.name }

    var conflictMessage: String {
        guard let serverName else {
            return String(localized: "This schedule changed on the server after you opened it. Your edit is kept.")
        }
        return String(localized: "This schedule changed on \(serverName) after you opened it. Your edit is kept.")
    }

    /// The text under the interval field: a blocking issue with the loaded schedule, or a bad number.
    var validationError: String? {
        guard intervalEnabled else { return nil }
        if let issue = loadedState.blockingIssue { return issue.message }
        if case .failure(let error) = ScheduleIntervalInput.parse(intervalMinutesText) { return error.message }
        return nil
    }

    /// The daily and weekly triggers, edited as rows. Changing none of them leaves those triggers on
    /// the server exactly as they were.
    var timed: [TimedTriggerDraft] = []
    private var loadedTimed: [TimedTriggerDraft] = []

    func addTimed(_ kind: TimedTriggerDraft.Kind) {
        timed.append(TimedTriggerDraft(kind: kind))
    }

    func removeTimed(id: UUID) {
        timed.removeAll { $0.id == id }
    }

    private var payload: [TaskTrigger]? {
        guard let snapshot else { return nil }
        guard let base = loadedState.makePayload(
            startupEnabled: startupEnabled,
            intervalEnabled: intervalEnabled,
            intervalInput: intervalMinutesText,
            triggers: snapshot.triggers
        ) else { return nil }
        return applyingTimed(to: base)
    }

    /// `base` holds the schedule's own daily and weekly triggers in their places. Rows that were not
    /// touched keep their trigger as read; a touched row is rebuilt; a removed row is dropped; new
    /// rows go last. Nil while a touched or new row is invalid.
    private func applyingTimed(to base: [TaskTrigger]) -> [TaskTrigger]? {
        guard timed.map(\.content) != loadedTimed.map(\.content) else { return base }
        var result: [TaskTrigger] = []
        var position = 0
        for trigger in base {
            guard trigger.isTimed else {
                result.append(trigger)
                continue
            }
            defer { position += 1 }
            guard let draft = timed.first(where: { $0.sourceIndex == position }) else { continue }
            if loadedTimed.indices.contains(position), loadedTimed[position].content == draft.content {
                result.append(trigger)
            } else {
                guard let rebuilt = draft.trigger() else { return nil }
                result.append(rebuilt)
            }
        }
        for draft in timed where draft.sourceIndex == nil {
            guard let created = draft.trigger() else { return nil }
            result.append(created)
        }
        return result
    }

    var canSave: Bool {
        guard let snapshot, !isBusy, !hasConflict, !task.manualOnly, let payload else { return false }
        return payload != snapshot.triggers
    }

    func open(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard !task.manualOnly else {
            errorMessage = failureText(String(localized: "This task only runs when you start it, so it has no schedule"))
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let read = try await readForEdit(client: client)
            snapshot = read
            fill(from: read.triggers)
            errorMessage = nil
        } catch {
            errorMessage = message(for: error, sessionState: sessionState)
        }
    }

    /// Returns true when the schedule was saved.
    func save(client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        guard canSave, let snapshot, let payload else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await client.updateTaskSchedule(key: task.key, triggers: payload, validator: snapshot.validator)
            return true
        } catch let error as APIError where error.statusCode == 412 || error.statusCode == 428 {
            hasConflict = true
            latest = nil
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

    /// Takes the current server schedule as the base for the next save; the form stays as typed.
    func adoptCurrent() {
        guard let latest else { return }
        snapshot = latest
        loadedState = TaskTrigger.scheduleEditorState(from: latest.triggers)
        // Daily and weekly rows the person did not touch follow the server's. Rows they did edit stay
        // as typed; those the current schedule has no counterpart for become new rows.
        let editedTimed = timed.map(\.content) != loadedTimed.map(\.content)
        var index = 0
        loadedTimed = latest.triggers.compactMap { trigger in
            guard trigger.isTimed else { return nil }
            defer { index += 1 }
            return TimedTriggerDraft(trigger: trigger, sourceIndex: index)
        }
        if editedTimed {
            for position in timed.indices {
                if let source = timed[position].sourceIndex, source >= loadedTimed.count {
                    timed[position].sourceIndex = nil
                }
            }
        } else {
            timed = loadedTimed
        }
        self.latest = nil
        hasConflict = false
    }

    private func fill(from triggers: [TaskTrigger]) {
        let state = TaskTrigger.scheduleEditorState(from: triggers)
        loadedState = state
        var index = 0
        loadedTimed = triggers.compactMap { trigger in
            guard trigger.isTimed else { return nil }
            defer { index += 1 }
            return TimedTriggerDraft(trigger: trigger, sourceIndex: index)
        }
        timed = loadedTimed
        startupEnabled = triggers.contains { $0.isStartup }
        intervalEnabled = state.intervalEnabled
        intervalMinutesText = state.intervalMinutesText
    }

    private func readForEdit(client: APIClient) async throws -> ScheduleSnapshot {
        let (schedule, validator) = try await client.taskSchedule(key: task.key)
        guard let validator, !validator.isEmpty else {
            throw ScheduleEditorError.missingValidator
        }
        return ScheduleSnapshot(triggers: schedule.triggers, validator: validator)
    }

    private func message(for error: Error, sessionState: ServerScopedSession?) -> String {
        if error is ScheduleEditorError {
            return failureText(String(localized: "The server did not allow this schedule to be edited safely. Try again later."))
        }
        return ErrorMessage.text(
            for: error, sessionState: sessionState,
            fallback: String(localized: "The schedule couldn't be saved. Try again."), serverName: serverName
        )
    }

    private func failureText(_ text: String) -> String {
        ErrorMessage.named(text, serverName: serverName)
    }
}

private enum ScheduleEditorError: Error {
    case missingValidator
}
