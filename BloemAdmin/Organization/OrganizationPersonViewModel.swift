import Foundation
import Observation

/// One person, from the routes an organization administrator has: the person (membership, profiles with their
/// access groups, last activity) and the organization's newest activity, narrowed to changes made to this person's
/// membership. The server offers no per-person activity route, so that part is "among the latest changes".
/// On a server with organization support (`support`), it also helps the person back in: reset links, sign-outs and
/// profile edits (OrganizationPersonSupport.swift). The server judges who may act on whom.
@Observable
@MainActor
final class OrganizationPersonViewModel {
    private(set) var isLoading = true
    private(set) var person: PersonSummary?
    /// The person is not (or no longer) in this organization: the server answered 404.
    private(set) var isGone = false
    private(set) var groups: [OrganizationAccessGroup] = []
    /// Changes to this person's membership found in the newest organization activity.
    private(set) var changes: [OrganizationAuditEvent] = []
    /// How many of the newest activity entries were looked through, so the list can say what it covers.
    private(set) var changesLooked = 0
    private(set) var changesUnavailable = false
    var isPending = false
    var errorMessage: String?
    var notice: String?
    @ObservationIgnored private var gate = LatestRequestGate()

    // MARK: Support (organization_support_v1)

    /// What the server offers on this page; all off on a server without organization support.
    var support = SupportCapabilities.none
    /// The person's live sign-ins and devices, when the server offers them; nil before they load.
    var sessions: [SupportSession]?
    var devices: [SupportDevice]?
    /// Why the sign-ins or devices could not be listed.
    var sessionsMessage: String?
    var devicesMessage: String?
    /// A reset link to hand over. Shown once and held only until the administrator closes it.
    var resetLink: ResetLinkHandoff?

    func load(session: OrganizationSession, accountID: Int64) async {
        let request = gate.begin()
        isLoading = person == nil
        errorMessage = nil
        let loaded: PersonSummary
        do {
            loaded = try await session.read { try await $0.organizationPerson(accountID: accountID) }
        } catch is CancellationError {
            return
        } catch let error as APIError where error.statusCode == 404 {
            // The server does not disclose people of other organizations: a 404 means "not in this one".
            guard gate.isCurrent(request) else { return }
            isLoading = false
            person = nil
            isGone = true
            return
        } catch {
            guard gate.isCurrent(request), !Task.isCancelled else { return }
            isLoading = false
            errorMessage = session.failureText(error, fallback: String(localized: "This person couldn't be loaded. Try again."))
            return
        }
        var loadedGroups = groups
        if loadedGroups.isEmpty, case .ok(let value) = await session.attemptRead(
            fallback: String(localized: "Access groups couldn't be loaded. Try again."), { try await $0.listOrganizationGroups() }
        ) {
            loadedGroups = value
        }
        let activity = await session.attemptRead(fallback: String(localized: "Activity couldn't be loaded. Try again.")) {
            try await $0.listOrganizationActivity(cursor: nil)
        }
        guard gate.isCurrent(request) else { return }
        isLoading = false
        person = loaded
        isGone = false
        groups = loadedGroups
        if case .ok(let page) = activity {
            changes = page.events.filter { $0.targetID == loaded.membershipID }
            changesLooked = page.events.count
            changesUnavailable = false
        } else {
            changes = []
            changesLooked = 0
            changesUnavailable = true
        }
        await loadSupport(session: session, person: loaded, request: request)
    }

    /// The support side of the page: what the server offers, then the person's sign-ins and devices. Your own are
    /// not listed: nobody helps themselves here.
    private func loadSupport(session: OrganizationSession, person: PersonSummary, request: Int) async {
        await session.loadSupportCapabilities()
        guard gate.isCurrent(request) else { return }
        support = session.support
        guard !person.isSelf(in: session.context) else {
            sessions = nil
            devices = nil
            return
        }
        await reloadSignIns(session: session, accountID: person.accountID)
    }

    /// Lists the person's sessions and devices again, each when the server offers it.
    func reloadSignIns(session: OrganizationSession, accountID: Int64) async {
        if support.sessions {
            switch await session.attemptRead(fallback: String(localized: "Their sign-ins couldn't be loaded. Try again."), {
                try await $0.organizationPersonSessions(accountID: accountID)
            }) {
            case .ok(let value): sessions = value; sessionsMessage = nil
            case .failed(let message): sessionsMessage = message
            case .cancelled: break
            }
        }
        if support.devices {
            switch await session.attemptRead(fallback: String(localized: "Their devices couldn't be loaded. Try again."), {
                try await $0.organizationPersonDevices(accountID: accountID)
            }) {
            case .ok(let value): devices = value; devicesMessage = nil
            case .failed(let message): devicesMessage = message
            case .cancelled: break
            }
        }
    }

    /// The person as the server answered a support write.
    func show(_ updated: PersonSummary) {
        person = updated
    }

    func dismissMessages() {
        errorMessage = nil
        notice = nil
    }

    func setSuspended(session: OrganizationSession, suspend: Bool) async {
        guard let person else { return }
        if suspend && person.isSelf(in: session.context) { return }
        let status = suspend ? PersonSummary.membershipSuspended : PersonSummary.membershipActive
        await change(
            session: session,
            refused: String(localized: "That membership can't be suspended. The owner always keeps access."),
            success: suspend ? String(localized: "Membership suspended") : String(localized: "Membership reactivated")
        ) { client, _ in
            try await client.setOrganizationMembershipStatus(accountID: person.accountID, status: status, revision: person.securityRevision)
        }
    }

    func assignGroup(session: OrganizationSession, profile: ProfileSummary, group: OrganizationAccessGroup) async {
        guard let person, let groupID = group.numericID else { return }
        await change(session: session, refused: nil, success: String(localized: "Profile moved to the access group")) { client, _ in
            try await client.setOrganizationProfileGroup(accountID: person.accountID, profileID: profile.id, groupID: groupID, revision: person.securityRevision)
        }
    }

    private func change(
        session: OrganizationSession,
        refused: String?,
        success: String,
        _ write: (APIClient, Int64) async throws -> PersonSummary
    ) async {
        guard let person, !isPending else { return }
        isPending = true
        errorMessage = nil
        notice = nil
        let outcome = await session.attemptWrite(
            fallback: String(localized: "The change couldn't be confirmed. Check the list before trying again."),
            refused: refused, write
        )
        switch outcome {
        case .ok(let updated):
            isPending = false
            self.person = updated
            notice = success
            // The change is on the record now; read the newest activity again.
            await refreshChanges(session: session, person: updated)
        case .failed(let message):
            isPending = false
            // The person may have changed under us: show what the server now holds, then say why.
            await load(session: session, accountID: person.accountID)
            errorMessage = message
        case .cancelled:
            isPending = false
        }
    }

    func refreshChanges(session: OrganizationSession, person: PersonSummary) async {
        if case .ok(let page) = await session.attemptRead(
            fallback: String(localized: "Activity couldn't be loaded. Try again."), { try await $0.listOrganizationActivity(cursor: nil) }
        ) {
            changes = page.events.filter { $0.targetID == person.membershipID }
            changesLooked = page.events.count
            changesUnavailable = false
        }
    }
}
