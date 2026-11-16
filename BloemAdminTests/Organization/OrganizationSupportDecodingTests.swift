import XCTest
@testable import BloemAdmin

/// The support routes' answers decode as the server writes them, older servers' answers still decode, and nothing a
/// support answer carries can put an address on screen.
final class OrganizationSupportDecodingTests: XCTestCase {
    typealias F = OrganizationFixtures

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.iso8601.decode(T.self, from: F.data(json))
    }

    func testCapabilitiesDecodeEveryFlag() throws {
        let all = try decode(SupportCapabilities.self, F.capabilities())
        XCTAssertTrue(all.passwordReset.email && all.passwordReset.link && all.sessions && all.devices)
        XCTAssertTrue(all.profiles.add && all.profiles.rename && all.profiles.clearPIN && all.profiles.remove)
        XCTAssertTrue(all.streams.list && all.streams.stop && all.streams.message)
        XCTAssertTrue(all.offersPersonSupport)

        let none = try decode(SupportCapabilities.self, F.capabilities(
            email: false, link: false, sessions: false, devices: false, add: false, rename: false, clearPIN: false,
            remove: false, list: false, stop: false, message: false
        ))
        XCTAssertEqual(none, .none)
        XCTAssertFalse(none.offersPersonSupport)
        XCTAssertThrowsError(try decode(SupportCapabilities.self, #"{"sessions":"yes"}"#), "a malformed flag fails the answer")
    }

    func testProfilesCarryTheirRevisionPINAndMainProfileFlag() throws {
        let profile = try decode(ProfileSummary.self, F.profile(revision: 9, hasPIN: true, isPrimary: true))
        XCTAssertEqual(profile.revision, 9)
        XCTAssertTrue(profile.hasPIN)
        XCTAssertTrue(profile.isPrimary)

        // A server that predates organization support sends none of them.
        let older = try decode(ProfileSummary.self, #"{"id":"p1","name":"Den","group_id":3,"group_name":"Family","updated_at":"2026-11-12T08:00:00Z"}"#)
        XCTAssertEqual(older.revision, 0)
        XCTAssertFalse(older.hasPIN)
        XCTAssertFalse(older.isPrimary)
    }

    func testAResetLinkDecodesAndIsNeverPrinted() throws {
        let link = try decode(SupportResetResponse.self, F.resetResponse())
        XCTAssertEqual(link.reset.delivery, "link")
        XCTAssertEqual(link.reset.deliveryStatus, "not_requested")
        XCTAssertEqual(link.reset.resetURL, "https://acme.example.test/reset-password/tok-123")
        XCTAssertEqual(link.person.accountID, 5)
        XCTAssertFalse(String(describing: link).contains("tok-123"))
        XCTAssertFalse(String(describing: link.reset).contains("tok-123"))
        let handoff = ResetLinkHandoff(url: "https://acme.example.test/reset-password/tok-123", expiresAt: "", personLabel: "Sam")
        XCTAssertFalse(String(describing: handoff).contains("tok-123"))

        let email = try decode(SupportResetResponse.self, F.resetResponse(delivery: "email", status: "failed_or_unknown"))
        XCTAssertNil(email.reset.resetURL, "an emailed link never comes back to the administrator")
        XCTAssertEqual(email.reset.deliveryStatus, SupportReset.deliveryUncertain)
    }

    func testSessionsAndDevicesDecodeWithTheirNulls() throws {
        let sessions = try decode(SupportSessionsResponse.self, F.supportSessions(
            F.supportSessionRow(), F.supportSessionRow(id: "s2", device: "Phone", profileID: nil, profileName: nil)
        )).sessions
        XCTAssertEqual(sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(sessions[0].profileName, "Living room")
        XCTAssertNil(sessions[1].profileID, "an account-login session belongs to no profile")
        XCTAssertEqual(sessions[0].lastSeenAt, "2026-11-13T11:00:00Z")

        let devices = try decode(SupportDevicesResponse.self, F.devices(F.device())).devices
        XCTAssertEqual(devices.first?.id, "dev-s1")
        XCTAssertEqual(devices.first?.profiles.map(\.profileName), ["Living room"])

        let signedOut = try decode(SupportSignOutResponse.self, F.signOutResponse(revision: 5, sessions: 3))
        XCTAssertEqual(signedOut.person.securityRevision, 5)
        XCTAssertEqual(signedOut.revoked.sessions, 3)
    }

    func testAStreamBecomesAPlaybackRowWithSupportFieldsOnly() throws {
        let page = try decode(SupportStreamsPage.self, F.streams(F.stream(), next: "cursor-2"))
        XCTAssertEqual(page.nextCursor, "cursor-2")
        let stream = try XCTUnwrap(page.streams.first)
        XCTAssertEqual(stream.watcherLabel, "Sam Rivers · Sam")
        XCTAssertTrue(stream.canStop)

        let row = stream.playbackRow
        XCTAssertEqual(row.sessionID, "st1")
        XCTAssertEqual(row.username, "Sam Rivers")
        XCTAssertEqual(row.profileName, "Sam")
        XCTAssertEqual(row.streamTitle, "Riverside · S2E5 · Episode name")
        XCTAssertEqual(row.streamMethod, .transcode)
        XCTAssertEqual(row.fileDuration, 2640)
        XCTAssertEqual(row.positionSeconds, 1310.5)
        XCTAssertEqual(row.streamClientLine, "Living room TV · Bloem 1.4.2 · Android TV")
        // Nothing that belongs to the server reaches the row.
        XCTAssertNil(row.streamLocation)
        XCTAssertNil(row.reportingNode)
        XCTAssertNil(row.nodeDisplayName)
        XCTAssertNil(row.routingExecutionNodeName)
        XCTAssertNil(row.routingEgressNodeName)
        XCTAssertNil(row.streamBitrateKbps)
        XCTAssertNil(row.sourceVideoCodec)

        // Opened, the organization's row says how it plays, never which node or network serves it.
        let organization = streamDetailRows(row, showClientIP: false, showServerRouting: false).map(\.kind)
        XCTAssertTrue(organization.contains(.method))
        XCTAssertTrue(organization.contains(.client))
        XCTAssertFalse(organization.contains(.node))
        XCTAssertFalse(organization.contains(.network))
        XCTAssertFalse(organization.contains(.clientIP))
        // The platform's row keeps its node line.
        XCTAssertTrue(streamDetailRows(row, showClientIP: false).map(\.kind).contains(.node))
    }

    func testAStreamFieldTheServerLeavesOutDecodesToNothing() throws {
        let stream = try decode(SupportStream.self, F.stream(series: false))
        XCTAssertNil(stream.seriesName)
        XCTAssertNil(stream.seasonNumber)
        XCTAssertEqual(stream.playbackRow.streamTitle, "Episode name")

        let open = try decode(SupportStream.self, F.stream().replacingOccurrences(of: #""duration_seconds":2640"#, with: #""duration_seconds":null"#))
        XCTAssertNil(open.durationSeconds, "a live or unknown length is null")
    }

    func testStopAndMessageAnswersDecode() throws {
        let stop = try decode(SupportStreamStopResult.self, F.stopResult(alreadyRevoked: true, notified: false))
        XCTAssertTrue(stop.alreadyRevoked)
        XCTAssertFalse(stop.clientNotified)
        let receipt = try decode(SessionCommandReceipt.self, F.messageReceipt(outcome: "replayed"))
        XCTAssertEqual(receipt.outcome, "replayed")
    }

    func testTheSupportPassDescribesItsAccess() throws {
        let response = try decode(AdminSessionResponse.self, F.supportSession())
        XCTAssertEqual(response.context.accessBasis, "support")
        XCTAssertEqual(response.context.supportAccessID, F.supportAccessID)
        XCTAssertEqual(response.context.supportExpiresAt, "2026-11-13T16:00:00Z")
        XCTAssertNil(response.context.membershipID)

        let member = try decode(AdminSessionResponse.self, F.session())
        XCTAssertEqual(member.context.accessBasis, "membership", "an older server sends no basis: a membership")
        XCTAssertNil(member.context.supportAccessID)
    }

    func testTheSupportRequestEncodesOnlyWhatItSays() throws {
        func json(_ request: AdminSessionRequest) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.iso8601.encode(request)) as? [String: Any])
        }
        let opening = try json(AdminSessionRequest(scope: "organization", organizationID: "o1", support: .opening(reason: "Locked out")))
        XCTAssertEqual(opening["support"] as? [String: String], ["reason": "Locked out"])
        let renewing = try json(AdminSessionRequest(scope: "organization", organizationID: "o1", support: .renewing(accessID: "a1")))
        XCTAssertEqual(renewing["support"] as? [String: String], ["access_id": "a1"])
        let platform = try json(AdminSessionRequest(scope: "platform", organizationID: nil))
        XCTAssertEqual(platform.keys.sorted(), ["scope"])
    }

    func testActivityShowsPlatformSupportWithoutAnAccount() throws {
        let page = try decode(OrganizationAuditPage.self, #"""
        {"events":[
          {"id":9,"source":"admin","created_at":"2026-11-13T12:00:00Z","actor_account_id":null,"actor_authority":"platform_support",
           "action":"support_access.opened","target_id":"\#(F.supportAccessID)","outcome":"success",
           "reason":"Admin locked out; helping her","support_access_id":"\#(F.supportAccessID)"},
          {"id":8,"source":"admin","created_at":"2026-11-13T11:00:00Z","actor_account_id":4,"actor_authority":"organization_admin",
           "action":"people.sessions_revoked","target_id":"m1","outcome":"success"},
          {"id":7,"source":"entitlement","created_at":"2026-11-13T10:00:00Z","actor_account_id":null,"actor_authority":null,
           "action":"entitlement.policy_assignment","target_id":"m1","outcome":"success"}
        ]}
        """#)
        XCTAssertTrue(page.events[0].isPlatformSupport)
        XCTAssertNil(page.events[0].actorAccountID)
        XCTAssertEqual(page.events[0].reason, "Admin locked out; helping her")
        XCTAssertFalse(page.events[1].isPlatformSupport)
        XCTAssertNil(page.events[2].actorAuthority)
    }

    func testTheFeatureTokenMarksAServerWithOrganizationSupport() throws {
        let current = try decode(BloemCapabilities.self, #"{"api":"bloem/v2","identity_schema":2,"features":{},"media_types":["movie"],"feature_tokens":["something_v2","organization_support_v1"]}"#)
        XCTAssertTrue(current.offersOrganizationSupport)
        let older = try decode(BloemCapabilities.self, #"{"api":"bloem/v2","identity_schema":2,"features":{},"media_types":[],"feature_tokens":[]}"#)
        XCTAssertFalse(older.offersOrganizationSupport)
    }

    func testAPersonWithOneProfileReplaced() throws {
        let person = try decode(PersonSummary.self, F.person(profiles: [F.profile(id: "p1", hasPIN: true), F.profile(id: "p2", name: "Kids")].joined(separator: ",")))
        let cleared = try decode(ProfileSummary.self, F.profile(id: "p1", revision: 3, hasPIN: false))

        let updated = person.replacing(cleared)

        XCTAssertEqual(updated.profiles.map(\.id), ["p1", "p2"])
        XCTAssertFalse(updated.profiles[0].hasPIN)
        XCTAssertEqual(updated.profiles[0].revision, 3)
        XCTAssertEqual(updated.securityRevision, person.securityRevision)
    }
}
