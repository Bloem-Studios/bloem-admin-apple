import Foundation
import Observation

/// The three changes the web's bulk bar offers.
enum BulkAction: Equatable {
    case suspend
    case reactivate
    case assignGroup(OrganizationAccessGroup)

    var kind: String {
        switch self {
        case .suspend: BulkKind.suspend
        case .reactivate: BulkKind.reactivate
        case .assignGroup: BulkKind.assignGroup
        }
    }
}

/// What a bulk change has done so far. `job` is the server's own job for "everyone who matches", or one the app
/// keeps itself while it changes the people the administrator picked one by one; both read the same.
struct BulkReport: Equatable {
    let action: BulkAction
    var job: BulkJob
    /// Names for the accounts the app knows, so a result row can say "Sam" and not just "Account 5".
    var names: [Int64: String] = [:]
    /// Set when following the job failed; what the job did by then is shown as it stood.
    var error: String?

    var isRunning: Bool { !job.isFinished && error == nil }
}

/// People: search, filter by status, access group and recent activity, sort, suspend or reactivate a membership,
/// move a profile to an access group, and the web's bulk actions. Writes quote the person's `security_revision`,
/// one at a time per person, and never replay. There is no password reset: the server offers none to organization
/// administrators.
///
/// Bulk changes come in the web's two shapes. "Select all N" asks the server to freeze everyone the filter matches
/// and runs one server job over that selection (`BulkJob`, followed until it finishes). People ticked one by one
/// cannot be named to the server's job (the route takes a filter, not account ids), so those get the same
/// single-person writes the row buttons use, one after another, with the same result summary.
@Observable
@MainActor
final class OrganizationPeopleViewModel {
    private(set) var isLoading = true
    private(set) var isLoadingMore = false
    private(set) var people: [PersonSummary] = []
    private(set) var nextCursor: String?
    private(set) var approximateTotal: Int64 = 0
    private(set) var filter = PeopleFilter()
    /// Access groups, for the filter and for moving a profile.
    private(set) var groups: [OrganizationAccessGroup] = []
    private(set) var pendingAccountIDs: Set<Int64> = []
    private(set) var errorMessage: String?
    /// A confirmation of the last change, or the reason the list was reloaded.
    private(set) var notice: String?
    /// True while the administrator is choosing people for a bulk change.
    private(set) var isSelecting = false
    /// People ticked one by one.
    private(set) var pickedIDs: Set<Int64> = []
    /// Everyone the filter matched when "Select all" was pressed; changed by one server job.
    private(set) var matching: PeopleSelection?
    private(set) var isMakingSelection = false
    private(set) var report: BulkReport?

    /// The time "active in the last N days" counts back from.
    @ObservationIgnored var now: () -> Date = { Date() }
    /// How long to wait between looks at a running server job.
    @ObservationIgnored var pollDelay: Duration = .seconds(1)
    /// Looks at one job at most this often before giving up; the job itself keeps running on the server.
    @ObservationIgnored var maxPolls = 600
    @ObservationIgnored private var gate = LatestRequestGate()

    /// How many people a bulk change would touch right now.
    var selectedCount: Int64 { matching?.matched ?? Int64(pickedIDs.count) }
    var hasSelection: Bool { matching != nil || !pickedIDs.isEmpty }
    var isBulkRunning: Bool { report?.isRunning == true }

    private static let maxFailedLooks = 3
    private static let localJob = "local"

    /// The filter as the server takes it: "last N days" becomes one instant, fixed when the filter is applied so
    /// every page of the list (whose cursor remembers the filter) and any selection use the same one.
    private func effective(_ requested: PeopleFilter) -> PeopleFilter {
        guard let days = requested.activeWithinDays else { return requested }
        var copy = requested
        let since = now().addingTimeInterval(-Double(days) * 86_400)
        copy.activeSince = ISO8601DateFormatter().string(from: since)
        return copy
    }

    private static func ignoringInstant(_ filter: PeopleFilter) -> PeopleFilter {
        var copy = filter
        copy.activeSince = nil
        return copy
    }

    /// Loads the groups once, then the first page with `requested`. A different filter drops the selection, as the
    /// web does.
    func load(session: OrganizationSession, filter requested: PeopleFilter? = nil) async {
        let request = gate.begin()
        let next = effective(requested ?? filter)
        let changed = Self.ignoringInstant(filter) != Self.ignoringInstant(next)
        isLoading = people.isEmpty || changed
        isLoadingMore = false
        filter = next
        errorMessage = nil
        if changed {
            matching = nil
            pickedIDs = []
        }
        var loadedGroups = groups
        if loadedGroups.isEmpty {
            // A failure to read groups only disables the group controls; people still load.
            if case .ok(let value) = await session.attemptRead(
                fallback: String(localized: "Access groups couldn't be loaded. Try again."), { try await $0.listOrganizationGroups() }
            ) {
                loadedGroups = value
            }
        }
        let outcome = await session.attemptRead(fallback: String(localized: "People couldn't be loaded. Try again.")) {
            try await $0.listOrganizationPeople(filter: next, cursor: nil)
        }
        guard gate.isCurrent(request) else { return }
        isLoading = false
        groups = loadedGroups
        switch outcome {
        case .ok(let page):
            people = page.items
            nextCursor = page.nextCursor
            approximateTotal = page.approximateTotal
            let present = Set(page.items.map(\.accountID))
            pickedIDs = pickedIDs.intersection(present)
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }

    func loadMore(session: OrganizationSession) async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        let request = gate.current()
        let current = filter
        isLoadingMore = true
        errorMessage = nil
        let outcome = await session.attemptRead(fallback: String(localized: "People couldn't be loaded. Try again.")) {
            try await $0.listOrganizationPeople(filter: current, cursor: cursor)
        }
        guard gate.isCurrent(request) else { return }
        isLoadingMore = false
        switch outcome {
        case .ok(let page):
            let seen = Set(people.map(\.accountID))
            people += page.items.filter { !seen.contains($0.accountID) }
            nextCursor = page.nextCursor
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }

    func dismissMessages() {
        errorMessage = nil
        notice = nil
    }

    func dismissReport() {
        if !isBulkRunning { report = nil }
    }

    // MARK: Choosing people

    func startSelecting() {
        isSelecting = true
        if !isBulkRunning { report = nil }
    }

    func stopSelecting() {
        guard !isBulkRunning else { return }
        isSelecting = false
        pickedIDs = []
        matching = nil
    }

    /// Ticks or unticks one person. Choosing by hand replaces a "select all" selection.
    func toggle(_ accountID: Int64) {
        guard !isBulkRunning else { return }
        isSelecting = true
        matching = nil
        if pickedIDs.contains(accountID) { pickedIDs.remove(accountID) } else { pickedIDs.insert(accountID) }
    }

    /// "Select all N": the server freezes everyone the current filter matches. Nothing changes yet.
    func selectAllMatching(session: OrganizationSession) async {
        guard !isMakingSelection, !isBulkRunning else { return }
        let current = filter
        let request = gate.current()
        isMakingSelection = true
        errorMessage = nil
        notice = nil
        isSelecting = true
        let outcome = await session.attemptRead(fallback: String(localized: "The selection couldn't be made. Try again.")) {
            try await $0.createOrganizationSelection(filter: current)
        }
        isMakingSelection = false
        // The filter changed while the server froze the old one: that selection names other people, so drop it.
        guard gate.isCurrent(request), Self.ignoringInstant(filter) == Self.ignoringInstant(current) else { return }
        switch outcome {
        case .ok(let selection):
            matching = selection
            pickedIDs = []
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }

    // MARK: Changing the chosen people

    /// Applies `action` to the chosen people. Needs a selection; one change at a time.
    func apply(session: OrganizationSession, action: BulkAction) async {
        guard !isBulkRunning, hasSelection else { return }
        if let matching {
            await runServerJob(session: session, action: action, selection: matching, known: people)
        } else {
            await runPicked(session: session, action: action, targets: people.filter { pickedIDs.contains($0.accountID) })
        }
    }

    private func runServerJob(session: OrganizationSession, action: BulkAction, selection: PeopleSelection, known: [PersonSummary]) async {
        let names = Dictionary(known.map { ($0.accountID, $0.label) }, uniquingKeysWith: { first, _ in first })
        let groupID: Int64? = { if case .assignGroup(let group) = action { return group.numericID } else { return nil } }()
        let started: BulkJob
        do {
            started = try await session.write { client, _ in
                try await client.startOrganizationBulkJob(selectionToken: selection.token, kind: action.kind, groupID: groupID)
            }
        } catch is CancellationError {
            return
        } catch {
            // A 409 means the selection is spent or out of date. A stale pass (401) says nothing about the selection,
            // whose token the server signed on its own: keep it, and the administrator can apply again.
            let expired = (error as? APIError)?.statusCode == 409
                || (error as? OrganizationStateChanged)?.wasConflict == true
            errorMessage = expired
                ? String(localized: "That selection expired. Select the people again.")
                : session.failureText(error, fallback: String(localized: "The change couldn't be started. Nothing was changed; check the list before trying again."))
            // An expired selection can't be used again; the rest of the failures leave it for another try.
            if expired { matching = nil }
            return
        }
        report = BulkReport(action: action, job: started, names: names)
        notice = nil
        errorMessage = nil
        var job = started
        var polls = 0
        var failedLooks = 0
        while !job.isFinished && polls < maxPolls {
            do { try await Task.sleep(for: pollDelay) } catch { return }
            polls += 1
            let jobID = job.jobID
            switch await session.attemptRead(fallback: String(localized: "The progress couldn't be checked. The change may still be running."), { try await $0.organizationBulkJob(id: jobID) }) {
            case .ok(let look):
                failedLooks = 0
                job = look
                report = BulkReport(action: action, job: job, names: names)
            case .failed(let message):
                failedLooks += 1
                if failedLooks >= Self.maxFailedLooks {
                    report = BulkReport(action: action, job: job, names: names, error: message)
                    // The job exists on the server and may still run: its selection is spent, so it cannot be
                    // applied a second time from here.
                    finishSelecting()
                    return
                }
            case .cancelled:
                return
            }
        }
        if !job.isFinished {
            report = BulkReport(
                action: action, job: job, names: names,
                error: String(localized: "This is taking a while. It keeps running on the server; open People again to see the result.")
            )
        }
        finishSelecting()
        await load(session: session)
    }

    private func finishSelecting() {
        isSelecting = false
        matching = nil
        pickedIDs = []
    }

    private enum OneResult {
        case changed(PersonSummary)
        case skipped(String)
        case failed(String)
        /// Stop the whole run; the text says why (nil when the task was cancelled).
        case abort(String?)
    }

    private func runPicked(session: OrganizationSession, action: BulkAction, targets: [PersonSummary]) async {
        let names = Dictionary(targets.map { ($0.accountID, $0.label) }, uniquingKeysWith: { first, _ in first })
        var job = BulkJob(jobID: Self.localJob, status: "running", progressTotal: Int64(targets.count))
        report = BulkReport(action: action, job: job, names: names)
        notice = nil
        errorMessage = nil
        var skipped: [BulkRecordResult] = []
        var failed: [BulkRecordResult] = []
        var succeeded: Int64 = 0
        var aborted: String??
        for (index, person) in targets.enumerated() {
            switch await changeOne(session: session, action: action, person: person) {
            case .changed(let updated):
                succeeded += 1
                people = people.map { $0.accountID == person.accountID ? updated : $0 }
            case .skipped(let reason): skipped.append(BulkRecordResult(accountID: person.accountID, reason: reason))
            case .failed(let reason): failed.append(BulkRecordResult(accountID: person.accountID, reason: reason))
            case .abort(let message): aborted = .some(message)
            }
            if aborted != nil { break }
            job = BulkJob(
                jobID: Self.localJob, status: "running", progressCurrent: Int64(index + 1), progressTotal: Int64(targets.count),
                succeeded: succeeded, skipped: skipped, failed: failed
            )
            report = BulkReport(action: action, job: job, names: names)
        }
        job = BulkJob(
            jobID: Self.localJob, status: aborted != nil ? "failed" : "completed", progressCurrent: job.progressCurrent,
            progressTotal: Int64(targets.count), succeeded: succeeded, skipped: skipped, failed: failed
        )
        report = BulkReport(action: action, job: job, names: names, error: aborted ?? nil)
        finishSelecting()
        await load(session: session)
    }

    private func changeOne(session: OrganizationSession, action: BulkAction, person: PersonSummary) async -> OneResult {
        switch action {
        case .suspend:
            // Suspending oneself would end this session; the server's own job skips the actor the same way.
            if person.isSelf(in: session.context) { return .skipped("actor_authority_target") }
            if person.isSuspended { return .skipped("already_applied") }
            return await writeOne(session: session, person: person, protectedReason: "protected_owner") { client, revision in
                try await client.setOrganizationMembershipStatus(accountID: person.accountID, status: PersonSummary.membershipSuspended, revision: revision)
            }
        case .reactivate:
            if person.isActive { return .skipped("already_applied") }
            if !person.isSuspended { return .skipped("not_suspended") }
            return await writeOne(session: session, person: person, protectedReason: "mutation_failed") { client, revision in
                try await client.setOrganizationMembershipStatus(accountID: person.accountID, status: PersonSummary.membershipActive, revision: revision)
            }
        case .assignGroup(let group):
            return await assignAll(session: session, person: person, group: group)
        }
    }

    /// Moves every profile that is not already in `group`, one write each, quoting the revision the last write returned.
    private func assignAll(session: OrganizationSession, person: PersonSummary, group: OrganizationAccessGroup) async -> OneResult {
        guard let groupID = group.numericID else { return .failed("mutation_failed") }
        if person.profiles.isEmpty { return .skipped("no_profiles") }
        let pending = person.profiles.filter { $0.groupID != groupID }
        if pending.isEmpty { return .skipped("already_applied") }
        var current = person
        for profile in pending {
            let snapshot = current
            switch await writeOne(session: session, person: snapshot, protectedReason: "mutation_failed", { client, revision in
                try await client.setOrganizationProfileGroup(accountID: snapshot.accountID, profileID: profile.id, groupID: groupID, revision: revision)
            }) {
            case .changed(let updated): current = updated
            case let other: return other
            }
        }
        return .changed(current)
    }

    private func writeOne(
        session: OrganizationSession,
        person: PersonSummary,
        protectedReason: String,
        _ block: (APIClient, Int64) async throws -> PersonSummary
    ) async -> OneResult {
        do {
            return .changed(try await session.write { client, _ in try await block(client, person.securityRevision) })
        } catch is CancellationError {
            return .abort(nil)
        } catch is OrganizationStateChanged {
            return .failed("authorization_state_changed")
        } catch let denied as OrganizationAccessDenied {
            return .abort(session.failureText(denied, fallback: personChangeFallback))
        } catch let error as APIError {
            switch error.statusCode {
            case 403: return .abort(session.failureText(error, fallback: personChangeFallback))
            case 404: return .failed("not_found")
            case 422: return .failed(protectedReason)
            default: return .failed("mutation_failed")
            }
        } catch {
            return .failed("mutation_failed")
        }
    }

    private var personChangeFallback: String {
        String(localized: "The change couldn't be confirmed. Check the list before trying again.")
    }

    // MARK: One person

    /// Suspends (`suspend` true) or reactivates a membership.
    func setSuspended(session: OrganizationSession, person: PersonSummary, suspend: Bool) async {
        // An administrator never suspends their own membership from here: it would end this session.
        if suspend && person.isSelf(in: session.context) { return }
        let status = suspend ? PersonSummary.membershipSuspended : PersonSummary.membershipActive
        await change(
            session: session, person: person,
            refused: String(localized: "That membership can't be suspended. The owner always keeps access."),
            success: suspend ? String(localized: "Membership suspended") : String(localized: "Membership reactivated")
        ) { client, _ in
            try await client.setOrganizationMembershipStatus(accountID: person.accountID, status: status, revision: person.securityRevision)
        }
    }

    /// Moves one profile of `person` to `group`.
    func assignGroup(session: OrganizationSession, person: PersonSummary, profile: ProfileSummary, group: OrganizationAccessGroup) async {
        guard let groupID = group.numericID else { return }
        await change(session: session, person: person, refused: nil, success: String(localized: "Profile moved to the access group")) { client, _ in
            try await client.setOrganizationProfileGroup(accountID: person.accountID, profileID: profile.id, groupID: groupID, revision: person.securityRevision)
        }
    }

    private func change(
        session: OrganizationSession,
        person: PersonSummary,
        refused: String?,
        success: String,
        _ write: (APIClient, Int64) async throws -> PersonSummary
    ) async {
        guard !pendingAccountIDs.contains(person.accountID), !isBulkRunning else { return }
        pendingAccountIDs.insert(person.accountID)
        errorMessage = nil
        notice = nil
        let outcome = await session.attemptWrite(fallback: personChangeFallback, refused: refused, write)
        pendingAccountIDs.remove(person.accountID)
        switch outcome {
        case .ok(let updated):
            people = people.map { $0.accountID == person.accountID ? updated : $0 }
            notice = success
        case .failed(let message):
            // The person may have changed under us: show what the server now holds, then say why.
            await load(session: session)
            errorMessage = message
        case .cancelled:
            break
        }
    }
}
