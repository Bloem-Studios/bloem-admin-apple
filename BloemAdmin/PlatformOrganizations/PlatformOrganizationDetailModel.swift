import Foundation
import Observation

/// Which organization an account may enter as an administrator, from what the app already knows: the organizations
/// the signed-in account administers, listed under each server (`router.organizations`). An organization the account
/// does not administer on this server gets no entry.
enum PlatformOrganizationAccess {
    static func scopeOrganization(organizationID: String, serverID: String, in administered: [ScopeOrganization]) -> ScopeOrganization? {
        administered.first { $0.serverID == serverID && $0.organizationID == organizationID }
    }
}

/// One organization on the platform: its status and counts, who owns it (by name), its members, and Suspend and
/// Reactivate. Every platform call goes through the platform pass; the owner's name falls back to the account lookup
/// the server Owner and platform administrators are allowed.
@Observable
@MainActor
final class PlatformOrganizationDetailModel {
    static let memberPageLimit = 100

    let organizationID: String
    private(set) var organization: OrganizationSummary?
    private(set) var members: [PlatformMembership] = []
    private(set) var membersCursor: String?
    private(set) var ownerName: String?
    private(set) var isLoading = true
    private(set) var isLoadingMoreMembers = false
    /// Why the organization could not be shown at all: the page shows this in place of its content.
    private(set) var failure: ServerSectionFailure?
    private(set) var isChangingStatus = false
    /// What the last change did, in words.
    private(set) var notice: String?
    /// Why the last change, or the last refresh, did not work.
    private(set) var actionError: String?

    var hasMoreMembers: Bool { membersCursor != nil }

    /// The owner as the page says it: a name, "Nobody yet" or "Not available". Never an account number.
    var ownerText: String {
        guard let organization else { return "" }
        guard organization.ownerAccountID != nil else { return String(localized: "Nobody yet") }
        return ownerName ?? String(localized: "Not available")
    }

    @ObservationIgnored private let account: APIClient
    @ObservationIgnored private let pass: PlatformPass
    @ObservationIgnored private var gate = LatestRequestGate()

    init(organizationID: String, account: APIClient, pass: PlatformPass) {
        self.organizationID = organizationID
        self.account = account
        self.pass = pass
    }

    /// The organization and its first page of members. Once something is on screen a failed refresh leaves it there
    /// and says why in `actionError`.
    func load(sessionState: ServerScopedSession?) async {
        let request = gate.begin()
        isLoading = organization == nil
        failure = nil
        do {
            let found = try await pass.read { try await $0.platformOrganization(id: organizationID) }
            let page = try await pass.read { try await $0.platformOrganizationMemberships(id: organizationID, cursor: nil, limit: Self.memberPageLimit) }
            guard gate.isCurrent(request) else { return }
            organization = found
            members = page.memberships
            membersCursor = page.nextCursor
            isLoading = false
            ownerName = await resolveOwnerName(for: found, in: page.memberships)
        } catch is CancellationError {
            return
        } catch {
            guard gate.isCurrent(request), !Task.isCancelled else { return }
            isLoading = false
            let fallback = String(localized: "This organization couldn't be loaded. Check the connection and try again.")
            if organization == nil {
                failure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: fallback)
            } else {
                actionError = ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback)
            }
        }
    }

    func loadMoreMembers(sessionState: ServerScopedSession?) async {
        guard let cursor = membersCursor, !isLoadingMoreMembers else { return }
        let request = gate.current()
        isLoadingMoreMembers = true
        defer { isLoadingMoreMembers = false }
        do {
            let page = try await pass.read { try await $0.platformOrganizationMemberships(id: organizationID, cursor: cursor, limit: Self.memberPageLimit) }
            guard gate.isCurrent(request) else { return }
            let known = Set(members.map(\.id))
            members += page.memberships.filter { !known.contains($0.id) }
            membersCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            guard gate.isCurrent(request), !Task.isCancelled else { return }
            actionError = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "More members couldn't be loaded. Check the connection and try again.")
            )
        }
    }

    // MARK: Suspend and reactivate

    /// Suspends (`true`) or reactivates (`false`) the organization on screen, quoting the revision the person saw.
    /// The write is sent once. When the organization moved on meanwhile it is reloaded and the person is told.
    func setSuspended(_ suspended: Bool, sessionState: ServerScopedSession?) async {
        guard let organization, !isChangingStatus else { return }
        isChangingStatus = true
        notice = nil
        actionError = nil
        defer { isChangingStatus = false }
        let name = organization.name
        let revision = organization.policyRevision
        do {
            _ = try await pass.write { client in
                if suspended {
                    return try await client.suspendPlatformOrganization(id: organization.id, expectedRevision: revision)
                }
                return try await client.reactivatePlatformOrganization(id: organization.id, expectedRevision: revision)
            }
            await load(sessionState: sessionState)
            if actionError == nil {
                notice = suspended ? String(localized: "\(name) is suspended") : String(localized: "\(name) is active again")
            } else {
                // Saved, but the page could not be refreshed: the status shown may be the old one.
                notice = suspended ? String(localized: "\(name) was suspended") : String(localized: "\(name) was reactivated")
            }
        } catch let changed as PlatformStateChanged {
            await load(sessionState: sessionState)
            actionError = changed.wasConflict
                ? String(localized: "Someone else changed this just now. It has been reloaded; check it and try again.")
                : String(localized: "Your administrator access was renewed. Check the organization and try again.")
        } catch is CancellationError {
            return
        } catch {
            actionError = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: suspended
                    ? String(localized: "\(name) couldn't be suspended. Check the connection and try again.")
                    : String(localized: "\(name) couldn't be reactivated. Check the connection and try again.")
            )
        }
    }

    // MARK: The owner

    /// The owner's name: from the members already loaded, else from the account lookup. Nil when neither knows.
    private func resolveOwnerName(for organization: OrganizationSummary, in members: [PlatformMembership]) async -> String? {
        guard let owner = organization.ownerAccountID else { return nil }
        if let member = members.first(where: { $0.accountID == owner }), Self.hasName(member) { return member.label }
        guard let user = try? await account.user(id: String(owner)).0 else { return nil }
        let name = user.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let email = user.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : email
    }

    private static func hasName(_ member: PlatformMembership) -> Bool {
        !member.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !member.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
