import Foundation
import Observation

/*
 One view model per organization page. Each takes the `OrganizationSession` on every call (never stores it), keeps
 its state in observable properties, and turns failures into text through `OrganizationSession.failureText`. Loads
 are guarded by a request counter so a slow answer never overwrites a newer one.
 */

/// Hands out request numbers; only the newest is current.
struct LatestRequestGate {
    private var latest = 0

    mutating func begin() -> Int {
        latest += 1
        return latest
    }

    func current() -> Int { latest }
    func isCurrent(_ request: Int) -> Bool { request == latest }
}

// MARK: - Overview

@Observable
@MainActor
final class OrganizationOverviewViewModel {
    private(set) var isLoading = true
    private(set) var summary: OrganizationSummary?
    /// The owner's name, read from the organization's own people list (the platform's account list is out of reach
    /// of an organization-only administrator). Nil until read, or when the person cannot be read.
    private(set) var ownerName: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private var gate = LatestRequestGate()

    /// The owner as the Overview says it: a name, "Nobody yet" or "Not available". Never an account number.
    var ownerText: String {
        guard let summary else { return "" }
        guard summary.ownerAccountID != nil else { return String(localized: "Nobody yet") }
        return ownerName ?? String(localized: "Not available")
    }

    func load(session: OrganizationSession) async {
        let request = gate.begin()
        isLoading = summary == nil
        errorMessage = nil
        let outcome = await session.attemptRead(fallback: String(localized: "This organization couldn't be loaded. Try again.")) {
            try await $0.organizationOverview()
        }
        guard gate.isCurrent(request) else { return }
        isLoading = false
        switch outcome {
        case .ok(let value):
            summary = value
            ownerName = await name(ofOwner: value.ownerAccountID, session: session)
            guard gate.isCurrent(request) else { return }
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }

    private func name(ofOwner accountID: Int64?, session: OrganizationSession) async -> String? {
        guard let accountID else { return nil }
        guard let person = try? await session.read({ try await $0.organizationPerson(accountID: accountID) }) else { return nil }
        let label = person.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }
}

// MARK: - Libraries & Entitlements

@Observable
@MainActor
final class OrganizationLibrariesViewModel {
    private(set) var isLoading = true
    private(set) var libraries: [OrganizationLibrary] = []
    private(set) var pendingFolderIDs: Set<Int64> = []
    private(set) var errorMessage: String?
    /// Set when a change went through, or was refused because the organization moved on (the list was reloaded).
    private(set) var notice: String?
    @ObservationIgnored private var gate = LatestRequestGate()

    func load(session: OrganizationSession) async {
        let request = gate.begin()
        isLoading = libraries.isEmpty
        errorMessage = nil
        let outcome = await session.attemptRead(fallback: String(localized: "Libraries couldn't be loaded. Try again.")) {
            try await $0.listOrganizationLibraries()
        }
        guard gate.isCurrent(request) else { return }
        isLoading = false
        switch outcome {
        case .ok(let value): libraries = value
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }

    func dismissMessages() {
        errorMessage = nil
        notice = nil
    }

    /// Pauses (`suspended`) or restores (`active`) a shared library's entitlement.
    func setStatus(session: OrganizationSession, library: OrganizationLibrary, status: String) async {
        guard let entitlement = library.entitlement, !library.isOwned else { return }
        let success = status == "active"
            ? String(localized: "Library restored")
            : String(localized: "Library paused. Members can't use it until you restore it.")
        _ = await run(session: session, library: library, success: success) { client in
            let updated = try await client.setOrganizationEntitlementStatus(
                folderID: library.folderID, status: status, revision: entitlement.securityRevision
            )
            self.libraries = self.libraries.map {
                $0.folderID == library.folderID
                    ? OrganizationLibrary(folderID: $0.folderID, name: $0.name, type: $0.type, accessKind: $0.accessKind, entitlement: updated)
                    : $0
            }
        }
    }

    /// Gives a shared library back for good. The web offers it for a shared library whose entitlement is not already
    /// withdrawn; only a platform administrator can share it again. The organization's own libraries have no
    /// entitlement and are never offered.
    func giveBack(session: OrganizationSession, library: OrganizationLibrary) async {
        guard let entitlement = library.entitlement, !library.isOwned, entitlement.status != "revoked" else { return }
        let done = await run(session: session, library: library, success: String(localized: "Library given back")) { client in
            try await client.deleteOrganizationEntitlement(folderID: library.folderID, revision: entitlement.securityRevision)
        }
        // The server keeps the row, now withdrawn; read it back rather than guess.
        if done { await load(session: session) }
    }

    private func run(
        session: OrganizationSession,
        library: OrganizationLibrary,
        success: String,
        _ block: (APIClient) async throws -> Void
    ) async -> Bool {
        guard !pendingFolderIDs.contains(library.folderID) else { return false }
        pendingFolderIDs.insert(library.folderID)
        errorMessage = nil
        notice = nil
        let outcome = await session.attemptWrite(
            fallback: String(localized: "The library change couldn't be confirmed. Check its status and try again.")
        ) { client, _ in try await block(client) }
        pendingFolderIDs.remove(library.folderID)
        switch outcome {
        case .ok:
            notice = success
            return true
        case .failed(let message):
            await load(session: session)
            errorMessage = message
            return false
        case .cancelled:
            return false
        }
    }
}

// MARK: - Activity & Audit

@Observable
@MainActor
final class OrganizationActivityViewModel {
    private(set) var isLoading = true
    private(set) var isLoadingOlder = false
    private(set) var events: [OrganizationAuditEvent] = []
    private(set) var nextCursor: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private var gate = LatestRequestGate()

    func load(session: OrganizationSession) async {
        let request = gate.begin()
        isLoading = events.isEmpty
        isLoadingOlder = false
        errorMessage = nil
        let outcome = await session.attemptRead(fallback: String(localized: "Activity couldn't be loaded. Try again.")) {
            try await $0.listOrganizationActivity(cursor: nil)
        }
        guard gate.isCurrent(request) else { return }
        isLoading = false
        switch outcome {
        case .ok(let page):
            events = page.events
            nextCursor = page.nextCursor
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }

    func loadOlder(session: OrganizationSession) async {
        guard let cursor = nextCursor, !isLoadingOlder else { return }
        let request = gate.current()
        isLoadingOlder = true
        errorMessage = nil
        let outcome = await session.attemptRead(fallback: String(localized: "Activity couldn't be loaded. Try again.")) {
            try await $0.listOrganizationActivity(cursor: cursor)
        }
        guard gate.isCurrent(request) else { return }
        isLoadingOlder = false
        switch outcome {
        case .ok(let page):
            let seen = Set(events.map { "\($0.source):\($0.id)" })
            events += page.events.filter { !seen.contains("\($0.source):\($0.id)") }
            nextCursor = page.nextCursor
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }
}

extension OrganizationAuditEvent {
    var isSuccess: Bool { outcome == "success" || outcome == "succeeded" }
}

// MARK: - Policy cohorts (read-only)

@Observable
@MainActor
final class OrganizationCohortsViewModel {
    private(set) var isLoading = true
    private(set) var cohorts: [EntitlementCohort] = []
    /// Library names, so a cohort's libraries read as names and not numbers.
    private(set) var libraries: [OrganizationLibrary] = []
    /// The web asks for archived cohorts too and files them under their own heading.
    private(set) var includeArchived = true
    private(set) var errorMessage: String?
    @ObservationIgnored private var gate = LatestRequestGate()

    var activeCohorts: [EntitlementCohort] { cohorts.filter { !$0.archived } }
    var archivedCohorts: [EntitlementCohort] { cohorts.filter(\.archived) }

    func load(session: OrganizationSession, includeArchived: Bool? = nil) async {
        let request = gate.begin()
        isLoading = true
        if let includeArchived { self.includeArchived = includeArchived }
        let include = self.includeArchived
        errorMessage = nil
        let outcome = await session.attemptRead(fallback: String(localized: "Cohorts couldn't be loaded. Try again.")) {
            try await $0.listOrganizationCohorts(includeArchived: include)
        }
        var names = libraries
        if names.isEmpty, case .ok(let loaded) = await session.attemptRead(
            fallback: String(localized: "Libraries couldn't be loaded. Try again."), { try await $0.listOrganizationLibraries() }
        ) {
            names = loaded
        }
        guard gate.isCurrent(request) else { return }
        isLoading = false
        libraries = names
        switch outcome {
        case .ok(let value): cohorts = value
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }

    /// The names of the libraries a cohort's policy reaches; `nil` means every library.
    func libraryNames(for policy: PolicyView) -> [String]? {
        guard let ids = policy.libraryIDs else { return nil }
        return ids.map { id in
            libraries.first { $0.folderID == id }?.name ?? String(localized: "Library \(id)")
        }
    }
}

// MARK: - Policy decisions (read-only)

@Observable
@MainActor
final class OrganizationDecisionsViewModel {
    private(set) var isLoading = true
    private(set) var isLoadingMore = false
    private(set) var decisions: [PolicyDecision] = []
    private(set) var nextCursor: String?
    private(set) var errorMessage: String?
    private(set) var libraries: [OrganizationLibrary] = []
    /// The check the administrator opened, once its detail has loaded.
    private(set) var selectedID: Int64?
    private(set) var detail: PolicyDecisionDetail?
    private(set) var isDetailLoading = false
    private(set) var detailErrorMessage: String?
    @ObservationIgnored private var gate = LatestRequestGate()

    func load(session: OrganizationSession) async {
        let request = gate.begin()
        isLoading = decisions.isEmpty
        isLoadingMore = false
        errorMessage = nil
        let outcome = await session.attemptRead(fallback: String(localized: "Access checks couldn't be loaded. Try again.")) {
            try await $0.listOrganizationPolicyDecisions(cursor: nil)
        }
        var names = libraries
        if names.isEmpty, case .ok(let loaded) = await session.attemptRead(
            fallback: String(localized: "Libraries couldn't be loaded. Try again."), { try await $0.listOrganizationLibraries() }
        ) {
            names = loaded
        }
        guard gate.isCurrent(request) else { return }
        isLoading = false
        libraries = names
        switch outcome {
        case .ok(let page):
            decisions = page.decisions
            nextCursor = page.nextCursor
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }

    func loadMore(session: OrganizationSession) async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        let request = gate.current()
        isLoadingMore = true
        errorMessage = nil
        let outcome = await session.attemptRead(fallback: String(localized: "Access checks couldn't be loaded. Try again.")) {
            try await $0.listOrganizationPolicyDecisions(cursor: cursor)
        }
        guard gate.isCurrent(request) else { return }
        isLoadingMore = false
        switch outcome {
        case .ok(let page):
            let seen = Set(decisions.map(\.id))
            decisions += page.decisions.filter { !seen.contains($0.id) }
            nextCursor = page.nextCursor
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }

    /// Opens one check: the list row shows the gist, the route behind it the rules and the libraries it could reach.
    func open(session: OrganizationSession, id: Int64) async {
        selectedID = id
        detail = nil
        isDetailLoading = true
        detailErrorMessage = nil
        let outcome = await session.attemptRead(fallback: String(localized: "This check couldn't be loaded. Try again.")) {
            try await $0.organizationPolicyDecision(id: id)
        }
        guard selectedID == id else { return }
        isDetailLoading = false
        switch outcome {
        case .ok(let value): detail = value
        case .failed(let message): detailErrorMessage = message
        case .cancelled: break
        }
    }

    func close() {
        selectedID = nil
        detail = nil
        isDetailLoading = false
        detailErrorMessage = nil
    }

    func libraryName(_ id: Int64) -> String {
        libraries.first { $0.folderID == id }?.name ?? String(localized: "Library \(id)")
    }
}

// MARK: - Access groups

@Observable
@MainActor
final class OrganizationGroupsViewModel {
    private(set) var isLoading = true
    private(set) var groups: [OrganizationAccessGroup] = []
    /// The libraries the organization has, for choosing which ones a group reaches.
    private(set) var libraries: [OrganizationLibrary] = []
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    /// The group "New group" just made, so the page can open it. Consumed with `consumeCreated()`.
    private(set) var createdID: String?
    /// Set when a delete moved profiles to the default group, so the notice can say how many.
    private(set) var lastDeletion: GroupDeletionImpact?
    @ObservationIgnored private var gate = LatestRequestGate()

    func load(session: OrganizationSession) async {
        let request = gate.begin()
        isLoading = groups.isEmpty
        errorMessage = nil
        let outcome = await session.attemptRead(fallback: String(localized: "Access groups couldn't be loaded. Try again.")) {
            try await $0.listOrganizationGroups()
        }
        // Libraries only feed the editor's choice list; the page works without them.
        let names = await session.attemptRead(fallback: String(localized: "Libraries couldn't be loaded. Try again.")) {
            try await $0.listOrganizationLibraries()
        }
        guard gate.isCurrent(request) else { return }
        isLoading = false
        if case .ok(let loaded) = names { libraries = loaded }
        switch outcome {
        case .ok(let value): groups = value
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }

    func dismissMessages() {
        errorMessage = nil
        notice = nil
        lastDeletion = nil
    }

    func consumeCreated() { createdID = nil }

    func create(session: OrganizationSession, name: String) async {
        guard !isSaving else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = String(localized: "Enter a name for the group")
            return
        }
        isSaving = true
        errorMessage = nil
        notice = nil
        lastDeletion = nil
        let outcome = await session.attemptWrite(
            fallback: String(localized: "The group couldn't be saved. Check it before trying again."),
            refused: Self.refusedText
        ) { client, revision in try await client.createOrganizationGroup(name: name, revision: revision) }
        if case .ok(let group) = outcome { createdID = group.id }
        await finish(session: session, outcome: outcome, success: String(localized: "Group created"))
    }

    func save(session: OrganizationSession, group: OrganizationAccessGroup, draft: AccessGroupDraft) async {
        guard !isSaving, let id = group.numericID else { return }
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = String(localized: "Enter a name for the group")
            return
        }
        isSaving = true
        errorMessage = nil
        notice = nil
        lastDeletion = nil
        let outcome = await session.attemptWrite(
            fallback: String(localized: "The group couldn't be saved. Check it before trying again."),
            refused: Self.refusedText
        ) { client, revision in try await client.updateOrganizationGroup(id: id, body: draft.body(revision: revision)) }
        await finish(session: session, outcome: outcome, success: String(localized: "Group saved"))
    }

    @discardableResult
    func delete(session: OrganizationSession, group: OrganizationAccessGroup) async -> Bool {
        guard !isSaving, let id = group.numericID else { return false }
        isSaving = true
        errorMessage = nil
        notice = nil
        lastDeletion = nil
        let outcome = await session.attemptWrite(
            fallback: String(localized: "The group couldn't be deleted. Check the list before trying again."),
            refused: Self.refusedText
        ) { client, revision in try await client.deleteOrganizationGroup(id: id, revision: revision) }
        if case .ok(let impact) = outcome { lastDeletion = impact }
        await finish(session: session, outcome: outcome, success: String(localized: "Group deleted"))
        if case .ok = outcome { return true }
        return false
    }

    private static var refusedText: String {
        String(localized: "The server refused that change. A group managed by a plan can only be changed there, and the default group can't be deleted.")
    }

    private func finish<T>(session: OrganizationSession, outcome: Outcome<T>, success: String) async {
        switch outcome {
        case .ok:
            isSaving = false
            notice = success
            // A group change can move the organization's policy revision; the next write must quote the new one.
            _ = try? await session.refresh()
            await load(session: session)
        case .failed(let message):
            isSaving = false
            // Show what the server holds, whether or not the write went through; a load clears the error, so say it after.
            await load(session: session)
            errorMessage = message
        case .cancelled:
            isSaving = false
        }
    }
}

// MARK: - Invitations

/// The one-time claim link of a sent or renewed invitation. The server shows the token once and never again, so
/// this is held in memory only, until the administrator dismisses it or leaves.
struct ClaimLink: Equatable, Identifiable, CustomStringConvertible {
    let invitation: OrganizationInvitation
    let url: String

    var id: String { invitation.id }
    var description: String { "ClaimLink(invitation: \(invitation.id), url: <redacted>)" }

    /// `https://<server>/invite/<token>`: the server hands back the token, the web builds this same link.
    static func url(for baseURL: URL, token: String) -> String {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        components.percentEncodedPath = "/invite/\(APIPath.segment(token))"
        return components.string ?? "\(baseURL.absoluteString)/invite/\(APIPath.segment(token))"
    }
}

enum InvitationResult: Equatable {
    case sent(ClaimLink)
    case failed(String)
}

/// Send, renew and revoke organization invitations. Organization invitations always create a member (`role=user`)
/// and nothing is emailed: the administrator gets the link and hands it over. Create and renew are submitted once
/// and never retried, since the claim token is shown only once.
@Observable
@MainActor
final class OrganizationInvitationsViewModel {
    private(set) var isLoading = true
    private(set) var invitations: [OrganizationInvitation] = []
    private(set) var groups: [OrganizationAccessGroup] = []
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var claimLink: ClaimLink?
    @ObservationIgnored private var gate = LatestRequestGate()
    @ObservationIgnored private var surfaceEpoch = 0

    func load(session: OrganizationSession) async {
        let request = gate.begin()
        isLoading = invitations.isEmpty
        errorMessage = nil
        let outcome = await session.attemptRead(fallback: String(localized: "Invitations couldn't be loaded. Try again.")) {
            try await $0.listOrganizationInvitations()
        }
        var loadedGroups = groups
        if loadedGroups.isEmpty, case .ok(let value) = await session.attemptRead(
            fallback: String(localized: "Access groups couldn't be loaded. Try again."), { try await $0.listOrganizationGroups() }
        ) {
            loadedGroups = value
        }
        guard gate.isCurrent(request) else { return }
        isLoading = false
        groups = loadedGroups
        switch outcome {
        case .ok(let value): invitations = value
        case .failed(let message): errorMessage = message
        case .cancelled: break
        }
    }

    func send(session: OrganizationSession, email: String, accessGroupID: Int64?, note: String?) async -> InvitationResult {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return .failed(String(localized: "Enter an email address")) }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return await handoff(session: session) { client, revision in
            try await client.createOrganizationInvitation(
                CreateOrganizationInvitation(
                    email: address, expectedRevision: revision, accessGroupID: accessGroupID,
                    note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote
                )
            )
        }
    }

    func resend(session: OrganizationSession, invitation: OrganizationInvitation) async -> InvitationResult {
        await handoff(session: session) { client, revision in
            try await client.resendOrganizationInvitation(id: invitation.id, revision: revision)
        }
    }

    @discardableResult
    func revoke(session: OrganizationSession, invitation: OrganizationInvitation) async -> Bool {
        isBusy = true
        errorMessage = nil
        let outcome = await session.attemptWrite(fallback: String(localized: "The invitation couldn't be revoked")) { client, revision in
            try await client.revokeOrganizationInvitation(id: invitation.id, revision: revision)
        }
        isBusy = false
        await load(session: session)
        if case .failed(let message) = outcome { errorMessage = message }
        if case .ok = outcome { return true }
        return false
    }

    private func handoff(
        session: OrganizationSession,
        _ write: (APIClient, Int64) async throws -> InvitationHandoff
    ) async -> InvitationResult {
        let epoch = surfaceEpoch
        isBusy = true
        errorMessage = nil
        let outcome = await session.attemptWrite(
            fallback: String(localized: "The invitation couldn't be confirmed. Check the list before sending again."),
            refused: String(localized: "That invitation wasn't accepted. Check the email address and access group."),
            write
        )
        switch outcome {
        case .ok(let handoff):
            // Keep the link before anything that can be cancelled: it is never shown again.
            let link = ClaimLink(
                invitation: handoff.invitation,
                url: ClaimLink.url(for: session.baseURL, token: handoff.claimToken)
            )
            isBusy = false
            claimLink = surfaceEpoch == epoch ? link : nil
            await load(session: session)
            return .sent(link)
        case .failed(let message):
            isBusy = false
            // A state change means the list is stale; an uncertain failure needs the real list.
            await load(session: session)
            errorMessage = message
            return .failed(message)
        case .cancelled:
            isBusy = false
            return .failed(String(localized: "The invitation couldn't be confirmed. Check the list before sending again."))
        }
    }

    func dismissError() { errorMessage = nil }
    func dismissClaimLink() { claimLink = nil }

    /// Releases the claim link and invalidates anything still in flight.
    func closeSurface() {
        surfaceEpoch += 1
        dismissClaimLink()
    }
}
