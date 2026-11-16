import Foundation

/// A platform write the server turned back because the administrator's state moved on: the pass was stale (a 401), or
/// the organization changed under the person (a 409 `authorization_state_changed`). The write was sent once and is
/// not sent again; the caller reloads what it showed and asks the person to look again.
struct PlatformStateChanged: Error, Equatable {
    /// True for a 409: someone else changed the thing. False for a stale pass, which was renewed.
    let wasConflict: Bool
}

/// The platform context pass (`POST /api/bloem/v2/admin/session` with `scope: platform`), kept in memory only, for the
/// pages that act across organizations: the Organizations pages and the Owner's Support access list. The pass is a
/// bearer credential: it is never saved or printed, and `close()` drops it when the page goes away.
///
/// A read that meets `401 authorization_state_stale` or `401 tenant_session_required` renews the pass once and is asked
/// again. A write is never asked again: a renewal only readies the pass for what the person does next.
@MainActor
final class PlatformPass {
    private let account: APIClient
    private let makePassClient: @MainActor (String) -> APIClient
    private var passClient: APIClient?

    init(account: APIClient, makePassClient: @escaping @MainActor (String) -> APIClient) {
        self.account = account
        self.makePassClient = makePassClient
    }

    convenience init(account: APIClient, baseURL: URL, session: URLSession? = nil) {
        let passSession = session ?? ProductionSession.make()
        self.init(account: account) { token in APIClient(baseURL: baseURL, accessToken: token, session: passSession) }
    }

    /// Runs one read with the pass, minting it first. A 401 renews the pass and asks again, once.
    func read<T>(_ block: (APIClient) async throws -> T) async throws -> T {
        let client = try await currentClient()
        do {
            return try await block(client)
        } catch let error as APIError where error.statusCode == 401 {
            return try await block(try await mintPlatformPass())
        }
    }

    /// Runs one write with the pass. It is sent once. A stale pass is renewed and a lost race is reported, both as
    /// `PlatformStateChanged`; any other refusal passes through for the caller to explain.
    func write<T>(_ block: (APIClient) async throws -> T) async throws -> T {
        let client = try await currentClient()
        do {
            return try await block(client)
        } catch let error as APIError where error.isStaleOrganizationState || error.statusCode == 401 {
            if error.statusCode == 401 { _ = try await mintPlatformPass() }
            throw PlatformStateChanged(wasConflict: error.statusCode == 409)
        }
    }

    /// Drops the pass when the page goes away; the next visit mints a new one.
    func close() {
        passClient = nil
    }

    private func currentClient() async throws -> APIClient {
        if let passClient { return passClient }
        return try await mintPlatformPass()
    }

    private func mintPlatformPass() async throws -> APIClient {
        let minted = try await account.mintAdminSession(AdminSessionRequest(scope: "platform", organizationID: nil))
        guard minted.context.scope == "platform" else {
            throw APIError(statusCode: 403, code: "insufficient_platform_authority", message: String(localized: "This account doesn't have platform administrator access."))
        }
        let client = makePassClient(minted.accessToken)
        passClient = client
        return client
    }
}
