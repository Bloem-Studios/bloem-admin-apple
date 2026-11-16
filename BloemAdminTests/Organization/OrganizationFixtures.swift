import Foundation
@testable import BloemAdmin

/// Bodies shaped exactly like the server's handlers write them (see the Bloem server's
/// OpenAPI document): same field names, string
/// ids where the server sends strings, numbers where it sends numbers, and `null` for nil sets, since the server does
/// not omit those.
enum OrganizationFixtures {
    static let orgID = "10000000-0000-0000-0000-000000000001"
    static let membershipID = "20000000-0000-0000-0000-000000000001"
    static let pass = "pass.jwt.value"
    static let base = "/api/bloem/v2/admin/organization"

    static func data(_ text: String) -> Data { Data(text.utf8) }

    static func memberships(_ rows: String...) -> String { #"{"organizations":[\#(rows.joined(separator: ","))]}"# }

    static func membership(
        id: String = orgID, name: String = "Acme Media", role: String = "admin",
        policyRevision: Int = 7, securityRevision: Int = 11
    ) -> String {
        #"{"id":"\#(id)","slug":"acme","name":"\#(name)","default":false,"membership_id":"\#(membershipID)","#
            + #""membership_role":"\#(role)","policy_revision":\#(policyRevision),"security_revision":\#(securityRevision)}"#
    }

    static func session(
        token: String = pass, organizationID: String = orgID, name: String = "Acme Media",
        authority: String = "organization_admin", policyRevision: Int = 7, scope: String = "organization",
        expiresAt: String = "2026-11-13T12:15:00Z"
    ) -> String {
        #"{"access_token":"\#(token)","expires_at":"\#(expiresAt)","context":{"key":"organization:\#(organizationID)","#
            + #""scope":"\#(scope)","organization_id":"\#(organizationID)","membership_id":"\#(membershipID)","name":"\#(name)","#
            + #""status":"active","authority":"\#(authority)","policy_revision":\#(policyRevision),"security_revision":11}}"#
    }

    static func overview(policyRevision: Int = 7) -> String {
        #"{"organization":{"id":"\#(orgID)","slug":"acme","name":"Acme Media","status":"active","owner_account_id":4,"#
            + #""policy_revision":\#(policyRevision),"is_default":false,"membership_count":12,"active_membership_count":10,"#
            + #""profile_count":25,"library_count":3,"entitlement_count":2}}"#
    }

    static func profile(
        id: String = "p1", name: String = "Living room", groupID: Int = 3, groupName: String = "Family",
        revision: Int = 2, hasPIN: Bool = false, isPrimary: Bool = false
    ) -> String {
        #"{"id":"\#(id)","name":"\#(name)","group_id":\#(groupID),"group_name":"\#(groupName)","updated_at":"2026-11-12T08:00:00.000Z","#
            + #""revision":\#(revision),"has_pin":\#(hasPIN),"is_primary":\#(isPrimary)}"#
    }

    static func person(
        accountID: Int = 5, email: String = "sam@example.test", name: String = "Sam", status: String = "active",
        revision: Int = 4, role: String = "user", profiles: String? = nil, membershipID: String? = nil
    ) -> String {
        let profiles = profiles ?? profile()
        return #"{"organization_id":"\#(orgID)","account_id":\#(accountID),"email":"\#(email)","display_name":"\#(name)","#
            + #""membership_id":"\#(membershipID ?? "person-membership-\(accountID)")","membership_status":"\#(status)","#
            + #""legacy_role":"\#(role)","security_revision":\#(revision),"last_activity":"2026-11-12T09:30:00.000Z","profiles":[\#(profiles)]}"#
    }

    static func peoplePage(_ people: String..., next: String? = nil, total: Int? = nil) -> String {
        let cursor = next.map { #""next_cursor":"\#($0)","# } ?? ""
        return #"{"items":[\#(people.joined(separator: ","))],\#(cursor)"approximate_total":\#(total ?? people.count)}"#
    }

    static func personResponse(_ json: String? = nil) -> String { #"{"person":\#(json ?? person())}"# }

    static func group(id: String = "3", name: String = "Family", isDefault: Bool = false, members: Int = 6) -> String {
        #"{"id":"\#(id)","name":"\#(name)","description":"","library_ids":["1","2"],"max_playback_quality":"original","#
            + #""download_allowed":true,"download_transcode_allowed":false,"transcode_allowed":true,"#
            + #""audio_transcode_allowed":true,"max_streams":2,"max_transcodes":1,"max_remote_stream_bitrate_kbps":0,"#
            + #""max_local_stream_bitrate_kbps":0,"max_profiles":5,"allowed_permissions":null,"requests_allowed":true,"#
            + #""is_default":\#(isDefault),"member_count":\#(members),"created_at":"2026-10-01T00:00:00.000Z","updated_at":"2026-10-02T00:00:00.000Z"}"#
    }

    static func groups(_ rows: String...) -> String { #"{"groups":[\#(rows.joined(separator: ","))]}"# }

    static func library(folderID: Int = 1, name: String = "Films", kind: String = "owned", entitlement: String? = nil) -> String {
        let extra = entitlement.map { #","entitlement":\#($0)"# } ?? ""
        return #"{"folder_id":\#(folderID),"name":"\#(name)","type":"movie","access_kind":"\#(kind)"\#(extra)}"#
    }

    static func entitlement(status: String = "active", revision: Int = 9) -> String {
        #"{"id":"30000000-0000-0000-0000-000000000001","organization_id":"\#(orgID)","status":"\#(status)","security_revision":\#(revision)}"#
    }

    static func libraries(_ rows: String...) -> String { #"{"libraries":[\#(rows.joined(separator: ","))]}"# }

    static func invitation(id: String = "i1", email: String = "new@example.test", status: String = "pending", groupID: String? = "3") -> String {
        let group = groupID.map { #""access_group_id":"\#($0)","# } ?? ""
        return #"{"id":"\#(id)","email":"\#(email)","delivery":"link","role":"user",\#(group)"#
            + #""library_ids":null,"create_profile":true,"show_tour":true,"note":"","invited_by":"4","invited_by_name":"Owner","#
            + #""status":"\#(status)","expires_at":"2026-11-20T00:00:00.000Z","created_at":"2026-11-13T00:00:00.000Z"}"#
    }

    static func invitations(_ rows: String...) -> String { #"{"invitations":[\#(rows.joined(separator: ","))]}"# }

    static func handoff(invitation json: String? = nil, token: String = "claim-token-value") -> String {
        #"{"invitation":\#(json ?? invitation()),"claim_token":"\#(token)"}"#
    }

    static func auditEvent(id: Int = 1, action: String = "people.membership_updated", outcome: String = "success", actor: Int = 4, target: String = "abc") -> String {
        #"{"id":\#(id),"source":"people","created_at":"2026-11-12T09:30:00.000Z","actor_account_id":\#(actor),"action":"\#(action)","#
            + #""target_id":"\#(target)","outcome":"\#(outcome)"}"#
    }

    static func audit(_ rows: String..., next: String? = nil) -> String {
        let cursor = next.map { #","next_cursor":"\#($0)""# } ?? ""
        return #"{"events":[\#(rows.joined(separator: ","))]\#(cursor)}"#
    }

    static func cohort(id: String = "c1", name: String = "Family plan", archived: Bool = false) -> String {
        #"{"cohort_id":"\#(id)","organization_id":"\#(orgID)","name":"\#(name)","revision":2,"access_group_id":3,"#
            + #""source_template_key":"family","source_template_revision":1,"parent_cohort_id":"c0","derivation_kind":"exact_template","policy":{"library_ids":null,"#
            + #""playback_allowed":true,"max_streams":2,"max_profiles":5,"transcode_allowed":true,"max_transcodes":1,"#
            + #""download_allowed":false,"download_transcode_allowed":false,"max_playback_quality":"original","#
            + #""allowed_permissions":null,"requests_allowed":true},"policy_digest":"d","archived":\#(archived),"member_count":6,"#
            + #""created_by_account_id":4,"created_at":"2026-10-01T00:00:00.000Z"}"#
    }

    static func cohorts(_ rows: String...) -> String { #"{"cohorts":[\#(rows.joined(separator: ","))]}"# }

    static func decision(id: Int = 1, action: String = "watch", allowed: Bool = true) -> String {
        #"{"id":\#(id),"timestamp":"2026-11-12T09:30:00.000Z","organization":{"id":"\#(orgID)"},"subject":{"account_id":5,"profile_id":"p1"},"#
            + #""group":{"id":3,"name":"Family"},"library_ceiling":[1,2],"action":"\#(action)","resource":{"library_id":1},"#
            + #""allowed":\#(allowed),"reason_code":"allowed_by_group","policy_versions":[{"kind":"group","version":2}]}"#
    }

    static func decisions(_ rows: String..., next: String? = nil) -> String {
        let cursor = next.map { #","next_cursor":"\#($0)""# } ?? ""
        return #"{"decisions":[\#(rows.joined(separator: ","))]\#(cursor)}"#
    }

    static func error(_ code: String, message: String = "Refused") -> String { #"{"error":"\#(code)","message":"\#(message)"}"# }

    // MARK: Selections, bulk jobs, group writes and decision detail

    static func selection(token: String = "sel-token", matched: Int = 12, excluded: Int = 0) -> String {
        #"{"selection":{"token":"\#(token)","matched":\#(matched),"excluded":\#(excluded),"expires_at":"2026-11-13T12:30:00.000Z"}}"#
    }

    static func bulkJob(
        status: String = "queued", current: Int = 0, total: Int = 12, succeeded: Int = 0,
        skipped: String = "", failed: String = "", jobID: String = "job-1"
    ) -> String {
        #"{"job":{"job_id":"\#(jobID)","status":"\#(status)","progress_current":\#(current),"progress_total":\#(total),"#
            + #""succeeded":\#(succeeded),"skipped":[\#(skipped)],"failed":[\#(failed)]}}"#
    }

    static func record(_ accountID: Int, _ reason: String) -> String { #"{"account_id":\#(accountID),"reason":"\#(reason)"}"# }

    static func groupMutation(group json: String? = nil, policyRevision: Int = 7) -> String {
        #"{"group":\#(json ?? group()),"policy_revision":\#(policyRevision)}"#
    }

    static func deletionImpact(reassigned: Int = 4, defaultGroup: Int = 3) -> String {
        #"{"profiles_reassigned":\#(reassigned),"default_group_id":\#(defaultGroup)}"#
    }

    static func decisionDetail(id: Int = 1, allowed: Bool = true, resource: String = #"{"library_id":1,"token":"[redacted]"}"#) -> String {
        #"{"decision":{"id":\#(id),"timestamp":"2026-11-12T09:30:00.000Z","organization":{"id":"\#(orgID)","membership_id":"\#(membershipID)"},"#
            + #""subject":{"account_id":5,"profile_id":"p1"},"group":{"id":3,"name":"Family"},"library_ceiling":[1,2],"#
            + #""action":"library_access_check","resource":\#(resource),"allowed":\#(allowed),"#
            + #""reason_code":"\#(allowed ? "allowed_by_group" : "library_not_in_ceiling")","#
            + #""policy_versions":[{"kind":"vendor","version":4},{"kind":"custom","name":"Kids rule","version":2}]}}"#
    }
}
