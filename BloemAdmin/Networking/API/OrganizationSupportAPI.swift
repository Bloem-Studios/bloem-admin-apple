import Foundation

/*
 Organization support routes (Bloem v2, `organization_support_v1`): what an organization administrator does to help
 their own people, and the server Owner's break-glass support access.

 Every /admin/organization route here takes the CONTEXT PASS as its bearer; the organization comes from the pass,
 never from the path or body. Who may act on whom is the server's judgement: a protected person is
 `409 target_protected` with a `reason`, never a 403, and a person, session, device, profile or stream outside the
 organization is the same `404` as one that does not exist.

 `bloemCapabilities` is public, and `listPlatformOrganizations` takes a PLATFORM pass: both serve the Owner's
 support-access page, outside the organization.
 */

private let supportBase = "/api/bloem/v2/admin/organization"

/// One page of every organization on the server (platform pass), for the Owner's support-access page.
struct PlatformOrganizationsPage: Decodable, Sendable {
    let organizations: [OrganizationSummary]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case organizations
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        organizations = try c.value(.organizations, [OrganizationSummary]())
        let cursor = try c.value(.nextCursor, nil as String?)
        nextCursor = (cursor?.isEmpty ?? true) ? nil : cursor
    }
}

extension APIClient {
    // MARK: What this server can do

    /// Context pass. Which support operations this server serves; a server without the route predates them.
    func organizationSupportCapabilities() async throws -> SupportCapabilities {
        try await get("\(supportBase)/support-capabilities")
    }

    /// No credential needed. The server's feature tokens; `organization_support_v1` marks the support routes.
    func bloemCapabilities() async throws -> BloemCapabilities {
        try await get("/api/bloem/v2/capabilities")
    }

    // MARK: Reset links

    /// Context pass. Issues a single-use reset link: emailed (24 h) or returned once for the administrator to hand
    /// over (4 h). `revision` is the person's `security_revision`; it is checked, not raised. Sent once: issuing
    /// again replaces the link, so a lost answer is never retried here.
    func issueOrganizationPasswordReset(accountID: Int64, delivery: PasswordResetDelivery, revision: Int64) async throws -> SupportResetResponse {
        try await post(
            "\(supportBase)/people/\(accountID)/password-reset",
            body: SupportResetRequest(expectedRevision: revision, delivery: delivery.rawValue)
        )
    }

    // MARK: Sessions and devices

    /// Context pass. The person's live sign-ins, newest first, at most 50.
    func organizationPersonSessions(accountID: Int64) async throws -> [SupportSession] {
        let response: SupportSessionsResponse = try await get("\(supportBase)/people/\(accountID)/sessions")
        return response.sessions
    }

    /// Context pass. Signs the person out everywhere: raises their `security_revision` (quoted as `revision`) and
    /// ends every session. Their personal API keys keep working.
    func signOutOrganizationPersonEverywhere(accountID: Int64, revision: Int64) async throws -> SupportSignOutResponse {
        try await deleteDecoding("\(supportBase)/people/\(accountID)/sessions", body: RevisionBody(expectedRevision: revision))
    }

    /// Context pass. Ends one session; succeeds when it had already ended. Answers 204.
    func signOutOrganizationPersonSession(accountID: Int64, sessionID: String) async throws {
        try await delete("\(supportBase)/people/\(accountID)/sessions/\(APIPath.segment(sessionID))")
    }

    /// Context pass. The devices the person's profiles in this organization have used.
    func organizationPersonDevices(accountID: Int64) async throws -> [SupportDevice] {
        let response: SupportDevicesResponse = try await get("\(supportBase)/people/\(accountID)/devices")
        return response.devices
    }

    /// Context pass. Ends the person's sessions from one device and forgets its registration. Answers 204.
    func signOutOrganizationPersonDevice(accountID: Int64, deviceID: String) async throws {
        try await delete("\(supportBase)/people/\(accountID)/devices/\(APIPath.segment(deviceID))")
    }

    // MARK: Profiles

    /// Context pass. Adds a profile; without `groupID` it joins the group the account's other profiles inherit.
    func createOrganizationProfile(accountID: Int64, name: String, groupID: Int64?) async throws -> SupportProfileResponse {
        try await post(
            "\(supportBase)/people/\(accountID)/profiles",
            body: SupportProfileCreate(name: name.trimmingCharacters(in: .whitespacesAndNewlines), groupID: groupID)
        )
    }

    /// Context pass. Renames a profile; `revision` is the profile's own revision. Nobody is signed out.
    func renameOrganizationProfile(accountID: Int64, profileID: String, name: String, revision: Int64) async throws -> SupportProfileResponse {
        try await patch(
            "\(supportBase)/people/\(accountID)/profiles/\(APIPath.segment(profileID))/details",
            body: SupportProfileRename(expectedRevision: revision, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    /// Context pass. Clears a forgotten PIN; the member chooses a new one. `revision` is the profile's own revision.
    func clearOrganizationProfilePIN(accountID: Int64, profileID: String, revision: Int64) async throws -> ProfileSummary {
        let response: SupportProfileOnlyResponse = try await deleteDecoding(
            "\(supportBase)/people/\(accountID)/profiles/\(APIPath.segment(profileID))/pin",
            body: RevisionBody(expectedRevision: revision)
        )
        return response.profile
    }

    /// Context pass. Removes a profile with its watch history and collections, for good. Answers 204.
    func removeOrganizationProfile(accountID: Int64, profileID: String, revision: Int64) async throws {
        try await delete(
            "\(supportBase)/people/\(accountID)/profiles/\(APIPath.segment(profileID))",
            body: RevisionBody(expectedRevision: revision)
        )
    }

    // MARK: Streams

    /// Context pass. One page of the organization's live streams, with support fields only.
    func listOrganizationStreams(cursor: String?, limit: Int = 100) async throws -> SupportStreamsPage {
        try await get("\(supportBase)/streams", query: ["cursor": cursor ?? "", "limit": String(limit)])
    }

    /// Context pass. Stops a stream with Silo's terminate: its authority is revoked, then the player is told.
    func stopOrganizationStream(sessionID: String) async throws -> SupportStreamStopResult {
        let response: SupportStreamStopResult = try await post(
            "\(supportBase)/streams/\(APIPath.segment(sessionID))/stop", body: EmptyBody()
        )
        return response
    }

    /// Context pass. Puts a message on the player. `identity` is allocated once per message; a retry reuses it.
    func messageOrganizationStream(sessionID: String, title: String?, message: String, identity: PlaybackCommandIdentity) async throws -> SessionCommandReceipt {
        try await post(
            "\(supportBase)/streams/\(APIPath.segment(sessionID))/message",
            body: SupportStreamMessage(commandID: identity.commandID, sequence: identity.sequence, title: title, message: message)
        )
    }

    // MARK: Break-glass support access

    /// Context pass opened under support access. Ends the access, and the pass with it. Answers 204.
    func closeOrganizationSupportAccess() async throws {
        try await delete("\(supportBase)/support-access")
    }

    /// PLATFORM pass. One page of the organizations on the server, optionally only those with `status` (`active`,
    /// `suspended` or `initializing`; nil is every status). Serves the Organizations page and Support access.
    func listPlatformOrganizations(query: String, status: String? = nil, cursor: String?, limit: Int = 100) async throws -> PlatformOrganizationsPage {
        try await get(
            "/api/bloem/v2/admin/platform/organizations",
            query: [
                "query": query.trimmingCharacters(in: .whitespacesAndNewlines), "status": status ?? "",
                "cursor": cursor ?? "", "limit": String(limit),
            ]
        )
    }
}
