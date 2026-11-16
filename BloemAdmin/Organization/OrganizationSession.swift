import Foundation
import Observation

/// Why the server turned an administrator away from an organization.
enum OrganizationDenial: Equatable, Sendable {
    /// `403 organization_suspended`: the organization itself is suspended.
    case suspended
    /// A 403 for the account: the role is no longer `admin`, the membership ended, or platform authority was lost.
    case lostAuthority
    /// `404`: the server does not show this organization to the account at all.
    case notFound
    /// The break-glass support access the pass was opened under has ended: closed, or past its four hours.
    case supportEnded

    var message: String {
        switch self {
        case .suspended: String(localized: "This organization is suspended. Contact the server owner.")
        case .lostAuthority: String(localized: "You no longer administer this organization")
        case .notFound: String(localized: "You don't have access to this organization")
        case .supportEnded: String(localized: "Support access to this organization has ended. To keep helping, open it again with a new reason.")
        }
    }
}

/// The server says this account may not administer this organization (403), or does not show it (404).
struct OrganizationAccessDenied: Error, Equatable, Sendable {
    let reason: OrganizationDenial
}

/// A write found the organization changed since it was loaded (stale pass, or a revision conflict). The pass has
/// been renewed; the write was NOT applied and must not be replayed. Reload, then ask again.
struct OrganizationStateChanged: Error, Equatable, Sendable {
    /// True for a `409 authorization_state_changed` (what was quoted is out of date); false for a stale pass (401).
    let wasConflict: Bool
}

extension APIError {
    /// The one reading of a refused request: the code decides suspended, the status decides the rest.
    var denialReason: OrganizationDenial {
        if code == "organization_suspended" { return .suspended }
        if statusCode == 404 { return .notFound }
        return .lostAuthority
    }

    /// `401 tenant_session_required`, `401 authorization_state_stale`, or `409 authorization_state_changed`.
    var isStaleOrganizationState: Bool {
        (statusCode == 401 && (code == "tenant_session_required" || code == "authorization_state_stale"))
            || (statusCode == 409 && code == "authorization_state_changed")
    }
}

/// One administrator's hold on one organization: exchanges the account's login session for a short-lived context
/// pass (`POST /api/bloem/v2/admin/session`), keeps the pass in memory only, and hands pages a client whose bearer
/// is the pass. Pages call `read` and `write`; nothing else ever sees the account token or the pass.
///
/// - A read that comes back 401 (`tenant_session_required`, `authorization_state_stale`, or an expired pass)
///   renews the pass once and is retried once. Parallel reads share one mint.
/// - Writes go through `write`: they are never replayed. A stale pass or revision conflict renews the pass and
///   throws `OrganizationStateChanged` so the caller reloads. A pass close to expiry is renewed first.
/// - The account client keeps its own refresh and re-login handling: a 401 on the mint reaches it, so an expired
///   sign-in still lands on today's re-login form.
@MainActor
@Observable
final class OrganizationSession {
    /// A pass is renewed before a write when it has less than this left.
    static let expiryMargin: TimeInterval = 60
    /// Used when the server's `expires_at` cannot be read: shorter than the 15 minutes a pass lives.
    static let fallbackLifetime: TimeInterval = 14 * 60

    let organizationID: String
    /// The server's address, for building links the server hands back as tokens.
    let baseURL: URL
    /// The organization's context as the server last described it; nil before `open()`.
    private(set) var context: AdminContext?
    /// Why the server refused this account the organization (403, 404, or a pass for another one); nil while it has not.
    private(set) var denial: OrganizationDenial?

    /// The account's own session on this server. Failure text reads it so a rejected sign-in reaches the same
    /// re-login form as everywhere else; the pass never touches it.
    @ObservationIgnored var accountSession: ServerScopedSession?

    /// What the support routes can do on this server; nil until the server has said (`loadSupportCapabilities`).
    private(set) var supportCapabilities: SupportCapabilities?

    /// True once the server has refused this account the organization.
    var accessDenied: Bool { denial != nil }
    /// The organization policy revision a write quotes. Zero before `open()`.
    var policyRevision: Int64 { context?.policyRevision ?? 0 }
    /// A pass is held and `close()` has not dropped it.
    var isOpen: Bool { passClient != nil && !isClosed }
    /// The pass was opened under break-glass support access (the server Owner), not a membership.
    var isSupportAccess: Bool { context?.isSupportAccess ?? false }
    /// What the support routes offer, all off until the server has said otherwise.
    var support: SupportCapabilities { supportCapabilities ?? .none }

    @ObservationIgnored private let account: APIClient
    @ObservationIgnored private let makePassClient: @MainActor (String) -> APIClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var passClient: APIClient?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var expiresAt = Date.distantPast
    @ObservationIgnored private var renewal: Task<Void, Error>?
    /// Set by `close()`: a renewal still in flight must not bring the pass back.
    @ObservationIgnored private var isClosed = false
    /// The reason the first support mint states. Sent once: every renewal names the access instead.
    @ObservationIgnored private var pendingSupportReason: String?
    /// The support access this session renews its pass under; nil for a membership.
    @ObservationIgnored private(set) var supportAccessID: String?

    /// `account` carries the account token (used for the mint only). `makePassClient` builds the client that
    /// carries a pass.
    init(
        account: APIClient,
        baseURL: URL,
        organizationID: String,
        now: @escaping () -> Date = { Date() },
        makePassClient: @escaping @MainActor (String) -> APIClient
    ) {
        self.account = account
        self.baseURL = baseURL
        self.organizationID = organizationID
        self.now = now
        self.makePassClient = makePassClient
    }

    /// The convenience the app uses: a pass client for `baseURL` on `session`.
    convenience init(
        account: APIClient,
        baseURL: URL,
        organizationID: String,
        session: URLSession? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        // One URLSession for every pass this session receives: a pass is renewed every few minutes, and a new
        // production session per pass would never be invalidated.
        let passSession = session ?? ProductionSession.make()
        self.init(account: account, baseURL: baseURL, organizationID: organizationID, now: now) { pass in
            APIClient(baseURL: baseURL, accessToken: pass, session: passSession)
        }
    }

    /// Mints the first pass. Throws `OrganizationAccessDenied` for 403/404, or the `APIError` otherwise.
    @discardableResult
    func open() async throws -> AdminContext {
        isClosed = false
        generation = 0
        let minted = try await mint()
        install(minted)
        return minted.context
    }

    /// The server Owner opens an organization they are not a member of, stating why (10 to 500 characters). The
    /// reason is shown to the organization's administrators in Activity; the access lasts four hours at most. A
    /// caller who may not do this gets the same `OrganizationAccessDenied(.notFound)` as any absent organization; a
    /// reason the server will not take is the server's `422`.
    @discardableResult
    func openSupport(reason: String) async throws -> AdminContext {
        supportAccessID = nil
        pendingSupportReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { pendingSupportReason = nil }
        return try await open()
    }

    /// Opens again under a support access this login session opened earlier and that is still open: no new reason.
    /// An access that has ended answers `OrganizationAccessDenied(.supportEnded)`.
    @discardableResult
    func resumeSupport(accessID: String) async throws -> AdminContext {
        pendingSupportReason = nil
        supportAccessID = accessID
        return try await open()
    }

    /// Ends the support access the pass was opened under; the pass ends with it and the session is closed. An access
    /// that had already ended counts as ended. Anything else (the server unreachable) throws and leaves it open.
    func endSupportAccess() async throws {
        guard supportAccessID != nil else { return }
        do {
            try await write { client, _ in try await client.closeOrganizationSupportAccess() }
        } catch let error as APIError where error.statusCode == 404 {
            // Already closed, or past its four hours.
        } catch let denied as OrganizationAccessDenied where denied.reason == .supportEnded {
            // The renewal before the close found the access already gone.
        }
        supportAccessID = nil
        markDenied(.supportEnded)
        close()
    }

    /// Asks the server which support operations it serves, once per session. A server without the route predates
    /// them: nothing new is offered. Any other failure leaves the answer unknown, so a later page asks again.
    func loadSupportCapabilities() async {
        guard supportCapabilities == nil else { return }
        do {
            supportCapabilities = try await read { try await $0.organizationSupportCapabilities() }
        } catch let error as APIError where error.statusCode == 404 || error.statusCode == 405 {
            supportCapabilities = SupportCapabilities.none
        } catch {
            // Unknown for now: nothing new is shown until an answer arrives.
        }
    }

    /// Whether this server has the organization live socket: it advertises `organization_live_v1` in its public
    /// capabilities. Any doubt (offline, an older server) is "no", and the pages keep what they did before. The
    /// account client's detector keeps a final answer; a failure to ask is asked again next time.
    func offersLive() async -> Bool {
        (try? await account.bloemCapabilitiesIfBloem())?.offersOrganizationLive ?? false
    }

    /// Renews the pass, for example after a conflict.
    @discardableResult
    func refresh() async throws -> AdminContext {
        try await renewPass(rejecting: generation)
        guard let context else { throw OrganizationAccessDenied(reason: .lostAuthority) }
        return context
    }

    /// Runs one read. A 401 renews the pass and asks again, once.
    func read<T>(_ block: (APIClient) async throws -> T) async throws -> T {
        let used = generation
        do {
            return try await block(try currentClient())
        } catch let error as APIError where error.statusCode == 401 {
            try await renewPass(rejecting: used)
            return try await runDenyingOn403 { try await block(try self.currentClient()) }
        } catch let error as APIError where error.statusCode == 403 {
            markDenied(error.denialReason)
            throw error
        }
    }

    /// Runs one write with the current organization policy revision. See the type comment for the failure rules.
    /// `block` receives the pass client and the revision to quote.
    func write<T>(_ block: (APIClient, Int64) async throws -> T) async throws -> T {
        if now() >= expiresAt.addingTimeInterval(-Self.expiryMargin) {
            try await renewPass(rejecting: generation)
        }
        let used = generation
        do {
            return try await block(try currentClient(), policyRevision)
        } catch let error as APIError {
            if error.isStaleOrganizationState || error.statusCode == 401 {
                try await renewPass(rejecting: used)
                throw OrganizationStateChanged(wasConflict: error.statusCode == 409)
            }
            if error.statusCode == 403 { markDenied(error.denialReason) }
            throw error
        }
    }

    /// Drops the pass. The session cannot be used again until `open()`.
    func close() {
        isClosed = true
        renewal?.cancel()
        renewal = nil
        passClient = nil
        context = nil
    }

    /// The first reason sticks: a suspended organization stays "suspended" even if a later call answers 403 plainly.
    func markDenied(_ reason: OrganizationDenial) {
        if denial == nil { denial = reason }
    }

    // MARK: Pass

    private struct Minted {
        let token: String
        let expiresAt: Date
        let context: AdminContext
    }

    private func currentClient() throws -> APIClient {
        guard let passClient else { throw OrganizationAccessDenied(reason: .lostAuthority) }
        return passClient
    }

    private func runDenyingOn403<T>(_ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch let error as APIError where error.statusCode == 403 {
            markDenied(error.denialReason)
            throw error
        }
    }

    /// Renews the pass unless someone already replaced the rejected one, and shares one mint between callers.
    private func renewPass(rejecting rejected: Int) async throws {
        guard !isClosed else { throw CancellationError() }
        if generation != rejected, passClient != nil { return }
        if let renewal {
            try await renewal.value
            return
        }
        let task = Task { @MainActor in
            let minted = try await self.mint()
            self.install(minted)
        }
        renewal = task
        defer { renewal = nil }
        try await task.value
    }

    /// What a mint asks for: a renewal names the support access it runs under; the first support mint states its
    /// reason; a membership asks for nothing more.
    private var supportRequest: SupportAccessRequest? {
        if let supportAccessID { return .renewing(accessID: supportAccessID) }
        if let pendingSupportReason { return .opening(reason: pendingSupportReason) }
        return nil
    }

    private func mint() async throws -> Minted {
        let support = supportRequest
        let response: AdminSessionResponse
        do {
            response = try await account.mintAdminSession(
                AdminSessionRequest(scope: "organization", organizationID: organizationID, support: support)
            )
        } catch let error as APIError where error.statusCode == 403 || error.statusCode == 404 {
            // A renewal the server no longer recognises means the support access itself is over.
            let reason: OrganizationDenial = support?.accessID != nil && error.statusCode == 404 ? .supportEnded : error.denialReason
            markDenied(reason)
            throw OrganizationAccessDenied(reason: reason)
        }
        let described = response.context
        // Never accept a pass the server did not issue for exactly this organization.
        guard described.scope == "organization", described.organizationID == organizationID else {
            markDenied(.lostAuthority)
            throw OrganizationAccessDenied(reason: .lostAuthority)
        }
        let supportAccessID = described.accessBasis == "support" ? described.supportAccessID : nil
        let context = AdminContext(
            key: described.key, name: described.name, scope: .organization, organizationID: organizationID,
            status: described.status,
            authority: described.authority == "platform_admin" ? .platformAdmin : .organizationAdmin,
            membershipID: described.membershipID, policyRevision: described.policyRevision,
            securityRevision: described.securityRevision,
            supportAccessID: supportAccessID,
            supportExpiresAt: supportAccessID == nil ? nil : described.supportExpiresAt.flatMap(Self.parseInstant)
        )
        let expiry = Self.parseInstant(response.expiresAt) ?? now().addingTimeInterval(Self.fallbackLifetime)
        return Minted(token: response.accessToken, expiresAt: expiry, context: context)
    }

    private func install(_ minted: Minted) {
        guard !isClosed else { return }
        generation += 1
        passClient = makePassClient(minted.token)
        expiresAt = minted.expiresAt
        context = minted.context
        // Renewals name the access from now on; the reason is never sent twice.
        supportAccessID = minted.context.supportAccessID
        pendingSupportReason = nil
    }

    private static func parseInstant(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
