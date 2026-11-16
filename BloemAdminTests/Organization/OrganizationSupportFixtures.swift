import Foundation
@testable import BloemAdmin

/// Bodies of the organization support routes, shaped as a Bloem server's handlers write them
/// and as the OpenAPI document's
/// BloemSupport* schemas declare them: `null` where the server sends null, omitted where it omits.
extension OrganizationFixtures {
    static let supportAccessID = "40000000-0000-0000-0000-000000000001"

    static func capabilities(
        email: Bool = true, link: Bool = true, sessions: Bool = true, devices: Bool = true,
        add: Bool = true, rename: Bool = true, clearPIN: Bool = true, remove: Bool = true,
        list: Bool = true, stop: Bool = true, message: Bool = true
    ) -> String {
        #"{"password_reset":{"email":\#(email),"link":\#(link)},"sessions":\#(sessions),"devices":\#(devices),"#
            + #""profiles":{"add":\#(add),"rename":\#(rename),"clear_pin":\#(clearPIN),"remove":\#(remove)},"#
            + #""streams":{"list":\#(list),"stop":\#(stop),"message":\#(message)}}"#
    }

    /// A pass opened under break-glass support access: no membership, `access_basis` support.
    static func supportSession(
        token: String = pass, expiresAt: String = "2026-11-13T12:15:00Z", supportExpiresAt: String = "2026-11-13T16:00:00Z",
        policyRevision: Int = 7
    ) -> String {
        #"{"access_token":"\#(token)","expires_at":"\#(expiresAt)","context":{"key":"organization:\#(orgID)","#
            + #""scope":"organization","organization_id":"\#(orgID)","name":"Acme Media","status":"active","#
            + #""authority":"platform_admin","policy_revision":\#(policyRevision),"access_basis":"support","#
            + #""support_access_id":"\#(supportAccessID)","support_expires_at":"\#(supportExpiresAt)"}}"#
    }

    static func resetResponse(delivery: String = "link", status: String? = nil, url: String? = "https://acme.example.test/reset-password/tok-123", revision: Int = 4) -> String {
        let deliveryStatus = status ?? (delivery == "link" ? "not_requested" : "sent")
        let link = delivery == "link" ? url.map { #","reset_url":"\#($0)""# } ?? "" : ""
        return #"{"reset":{"delivery":"\#(delivery)","delivery_status":"\#(deliveryStatus)"\#(link),"expires_at":"2026-11-13T16:00:00Z"},"#
            + #""person":\#(person(revision: revision))}"#
    }

    static func supportSessionRow(id: String = "s1", device: String = "Living room TV", profileID: String? = "p1", profileName: String? = "Living room") -> String {
        let profileIDJSON = profileID.map { #""\#($0)""# } ?? "null"
        let profileNameJSON = profileName.map { #""\#($0)""# } ?? "null"
        return #"{"id":"\#(id)","device_name":"\#(device)","device_id":"dev-\#(id)","device_platform":"androidtv","#
            + #""auth_method":"password","profile_id":\#(profileIDJSON),"profile_name":\#(profileNameJSON),"#
            + #""created_at":"2026-11-12T08:00:00Z","last_seen_at":"2026-11-13T11:00:00Z","expires_at":"2026-12-12T08:00:00Z"}"#
    }

    static func supportSessions(_ rows: String...) -> String { #"{"sessions":[\#(rows.joined(separator: ","))]}"# }

    static func device(id: String = "dev-s1", name: String = "Living room TV") -> String {
        #"{"device_id":"\#(id)","name":"\#(name)","platform":"androidtv","last_seen_at":"2026-11-13T11:00:00Z","#
            + #""profiles":[{"profile_id":"p1","profile_name":"Living room"}]}"#
    }

    static func devices(_ rows: String...) -> String { #"{"devices":[\#(rows.joined(separator: ","))]}"# }

    static func signOutResponse(revision: Int = 5, sessions: Int = 3) -> String {
        #"{"person":\#(person(revision: revision)),"revoked":{"sessions":\#(sessions)}}"#
    }

    static func profileResponse(profile json: String? = nil, person personJSON: String? = nil) -> String {
        #"{"profile":\#(json ?? profile()),"person":\#(personJSON ?? person())}"#
    }

    static func profileOnlyResponse(_ json: String? = nil) -> String { #"{"profile":\#(json ?? profile())}"# }

    static func stream(
        id: String = "st1", person: String = "Sam Rivers", profile: String = "Sam", title: String = "Episode name",
        series: Bool = true, canStop: Bool = true, canMessage: Bool = true, paused: Bool = false
    ) -> String {
        let seriesJSON = series ? #""series_name":"Riverside","season_number":2,"episode_number":5,"# : ""
        return #"{"session_id":"\#(id)","account_id":42,"person_name":"\#(person)","profile_id":"p42","profile_name":"\#(profile)","#
            + #""title":"\#(title)",\#(seriesJSON)"media_type":"episode","started_at":"2026-11-13T11:00:00Z","#
            + #""updated_at":"2026-11-13T11:20:00Z","position_seconds":1310.5,"duration_seconds":2640,"is_paused":\#(paused),"#
            + #""play_method":"transcode","video_decision":"transcode","audio_decision":"direct","#
            + #""device":{"name":"Living room TV","platform":"androidtv","id":"dev-1","app":"Bloem 1.4.2"},"#
            + #""can_stop":\#(canStop),"can_message":\#(canMessage)}"#
    }

    static func streams(_ rows: String..., next: String? = nil) -> String {
        let cursor = next.map { #","next_cursor":"\#($0)""# } ?? ""
        return #"{"streams":[\#(rows.joined(separator: ","))]\#(cursor)}"#
    }

    static func stopResult(id: String = "st1", alreadyRevoked: Bool = false, notified: Bool = true) -> String {
        #"{"session_id":"\#(id)","authority_revoked":true,"already_revoked":\#(alreadyRevoked),"client_notified":\#(notified)}"#
    }

    static func messageReceipt(outcome: String = "applied") -> String {
        #"{"command_id":"c1","sequence":1,"outcome":"\#(outcome)","delivery":"dispatched"}"#
    }

    static func protected(_ reason: String) -> String {
        #"{"error":"target_protected","message":"This person is protected from this action","reason":"\#(reason)"}"#
    }

    static func notConfigured(_ capability: String) -> String {
        #"{"error":"capability_not_configured","message":"This server cannot deliver that kind of reset link","capability":"\#(capability)"}"#
    }
}
