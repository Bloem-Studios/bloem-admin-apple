import Foundation
import Observation

/// An organization is one row of the list and the subject of the reason sheet.
extension OrganizationSummary: Identifiable {}

/// Whether a server's platform menu offers Support Access: the server advertises `organization_support_v1`, and
/// the signed-in account is the server Owner (the only account the server lets open an organization this way).
/// Anything the app cannot confirm leaves the page out.
enum SupportAccessEligibility {
    static func check(client: APIClient) async -> Bool {
        guard let capabilities = try? await client.bloemCapabilitiesIfBloem(), capabilities.offersOrganizationSupport else { return false }
        guard let me = try? await client.currentAccount(), let account = try? await client.user(id: me.id).0 else { return false }
        return account.isOwner
    }
}

/// A support access this app opened during this run: reopening it within its four hours needs no new reason.
struct OpenSupportAccess: Equatable, Sendable {
    let accessID: String
    let expiresAt: Date?
}

/// The server Owner's list of organizations to open for support. It holds a platform pass (memory only) for the
/// list, leaves out the organizations the Owner already belongs to (those open from the context menu without a
/// reason), and remembers the accesses it opened.
@Observable
@MainActor
final class SupportAccessListModel {
    static let pageLimit = 100
    static let pageCap = 10
    static let reasonRange = 10...500

    private(set) var organizations: [OrganizationSummary] = []
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var openAccesses: [String: OpenSupportAccess] = [:]
    var query = ""

    @ObservationIgnored private let account: APIClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let platformPass: PlatformPass
    @ObservationIgnored private var gate = 0

    init(account: APIClient, now: @escaping () -> Date = { Date() }, platformPass: PlatformPass) {
        self.account = account
        self.now = now
        self.platformPass = platformPass
    }

    convenience init(account: APIClient, baseURL: URL, session: URLSession? = nil, now: @escaping () -> Date = { Date() }) {
        self.init(account: account, now: now, platformPass: PlatformPass(account: account, baseURL: baseURL, session: session))
    }

    /// The organizations matching `query`, every page up to `pageCap`. A stale platform pass is renewed once.
    func load(sessionState: ServerScopedSession?) async {
        gate += 1
        let request = gate
        isLoading = organizations.isEmpty
        errorMessage = nil
        do {
            let found = try await listAll(query: query)
            let memberIDs = Set((try? await account.listOrganizationMemberships())?.map(\.id) ?? [])
            guard request == gate else { return }
            organizations = found.filter { $0.status == "active" && !memberIDs.contains($0.id) }
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard request == gate, !Task.isCancelled else { return }
            isLoading = false
            errorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "The organizations couldn't be loaded. Try again."))
        }
    }

    private func listAll(query: String) async throws -> [OrganizationSummary] {
        var found: [OrganizationSummary] = []
        var cursor: String?
        for _ in 0..<Self.pageCap {
            let page = try await platformPass.read {
                try await $0.listPlatformOrganizations(query: query, status: "active", cursor: cursor, limit: Self.pageLimit)
            }
            found += page.organizations
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return found
    }

    /// Drops the platform pass when the page goes away; the next visit mints a new one.
    func close() {
        platformPass.close()
    }

    // MARK: Opening

    /// The reason as the server takes it: one line, trimmed, 10 to 500 characters.
    static func cleanedReason(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespaces)
    }

    static func isAcceptable(reason: String) -> Bool {
        reasonRange.contains(cleanedReason(reason).count)
    }

    /// An access opened earlier in this run and not yet over, for `organizationID`.
    func openAccess(for organizationID: String) -> OpenSupportAccess? {
        guard let access = openAccesses[organizationID] else { return nil }
        if let expiresAt = access.expiresAt, expiresAt <= now() { return nil }
        return access
    }

    /// Remembers the access `session` holds, or forgets the organization's when it has ended.
    func record(_ session: OrganizationSession) {
        if let accessID = session.supportAccessID, session.isOpen {
            openAccesses[session.organizationID] = OpenSupportAccess(accessID: accessID, expiresAt: session.context?.supportExpiresAt)
        } else {
            openAccesses[session.organizationID] = nil
        }
    }

    /// Opens `organizationID` under support access: renews an access this run already holds, else states `reason`.
    /// Returns the opened session, or text saying why it could not be opened.
    func open(
        organizationID: String,
        reason: String?,
        makeSession: @MainActor (String) -> OrganizationSession,
        sessionState: ServerScopedSession?
    ) async -> Result<OrganizationSession, SupportOpenFailure> {
        // One past its four hours is forgotten: the server would refuse it.
        if openAccesses[organizationID] != nil, openAccess(for: organizationID) == nil { openAccesses[organizationID] = nil }
        if let held = openAccess(for: organizationID) {
            let session = makeSession(organizationID)
            do {
                try await session.resumeSupport(accessID: held.accessID)
                record(session)
                return .success(session)
            } catch {
                // Ended since: a new reason is needed.
                openAccesses[organizationID] = nil
                guard let reason else { return .failure(.reasonNeeded) }
                return await openFresh(organizationID: organizationID, reason: reason, makeSession: makeSession, sessionState: sessionState)
            }
        }
        guard let reason else { return .failure(.reasonNeeded) }
        return await openFresh(organizationID: organizationID, reason: reason, makeSession: makeSession, sessionState: sessionState)
    }

    private func openFresh(
        organizationID: String,
        reason: String,
        makeSession: @MainActor (String) -> OrganizationSession,
        sessionState: ServerScopedSession?
    ) async -> Result<OrganizationSession, SupportOpenFailure> {
        let session = makeSession(organizationID)
        do {
            try await session.openSupport(reason: Self.cleanedReason(reason))
            record(session)
            return .success(session)
        } catch {
            return .failure(.refused(Self.openFailureText(error, sessionState: sessionState)))
        }
    }

    static func openFailureText(_ error: Error, sessionState: ServerScopedSession?) -> String {
        if let denied = error as? OrganizationAccessDenied {
            switch denied.reason {
            case .notFound, .lostAuthority, .supportEnded:
                return String(localized: "This organization can't be opened for support. Only the server Owner can open an active organization this way.")
            case .suspended:
                return OrganizationDenial.suspended.message
            }
        }
        if let api = error as? APIError {
            if api.statusCode == 422 {
                return String(localized: "Say why you're opening this organization, in 10 to 500 characters")
            }
            if api.statusCode == 429 {
                return OrganizationVocabulary.rateLimited(retryAfter: api.retryAfter)
            }
        }
        return ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "The organization couldn't be opened"))
    }
}

enum SupportOpenFailure: Error, Equatable {
    /// No access is held for it: ask for a reason.
    case reasonNeeded
    case refused(String)
}
