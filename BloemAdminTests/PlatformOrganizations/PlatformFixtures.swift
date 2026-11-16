import Foundation
@testable import BloemAdmin

/// Bodies shaped exactly like the server's platform handlers write them (see the Bloem server's OpenAPI document): same field names, `null` for a nil library set, the
/// owner's account number as a number, and nothing the server does not send.
enum PlatformFixtures {
    static let orgID = "30000000-0000-0000-0000-000000000001"
    static let otherOrgID = "30000000-0000-0000-0000-000000000002"
    static let base = "/api/bloem/v2/admin/platform/organizations"
    static let templates = "/api/bloem/v2/admin/platform/entitlement-templates"
    static let mint = "/api/bloem/v2/admin/session"

    static func data(_ text: String) -> Data { Data(text.utf8) }

    static func platformPass(_ token: String = "platform-pass") -> String {
        #"{"access_token":"\#(token)","expires_at":"2026-11-13T12:15:00Z","context":{"key":"platform","scope":"platform","name":"Platform","status":"active","authority":"platform_admin"}}"#
    }

    static func organization(
        id: String = orgID, name: String = "Riverside Club", slug: String = "riverside", status: String = "active",
        owner: Int? = 4, revision: Int = 7, members: Int = 12, active: Int = 10, profiles: Int = 25, libraries: Int = 3, shared: Int = 2
    ) -> String {
        let owner = owner.map { #""owner_account_id":\#($0),"# } ?? ""
        return #"{"id":"\#(id)","slug":"\#(slug)","name":"\#(name)","status":"\#(status)",\#(owner)"policy_revision":\#(revision),"#
            + #""is_default":false,"membership_count":\#(members),"active_membership_count":\#(active),"profile_count":\#(profiles),"#
            + #""library_count":\#(libraries),"entitlement_count":\#(shared)}"#
    }

    static func page(_ rows: String..., next: String? = nil) -> String {
        let cursor = next.map { #","next_cursor":"\#($0)""# } ?? ""
        return #"{"organizations":[\#(rows.joined(separator: ","))]\#(cursor)}"#
    }

    static func detail(_ organization: String = organization()) -> String { #"{"organization":\#(organization)}"# }

    /// The suspend and reactivate answer: the organization without counts.
    static func changed(status: String, revision: Int) -> String {
        #"{"organization":{"id":"\#(orgID)","slug":"riverside","name":"Riverside Club","status":"\#(status)","owner_account_id":4,"policy_revision":\#(revision),"is_default":false}}"#
    }

    static func member(
        id: String, account: Int, username: String, email: String, role: String = "user", status: String = "active", revision: Int = 3
    ) -> String {
        #"{"id":"\#(id)","organization_id":"\#(orgID)","account_id":\#(account),"status":"\#(status)","legacy_role":"\#(role)","#
            + #""security_revision":\#(revision),"email":"\#(email)","username":"\#(username)"}"#
    }

    static func members(_ rows: String..., next: String? = nil) -> String {
        let cursor = next.map { #","next_cursor":"\#($0)""# } ?? ""
        return #"{"memberships":[\#(rows.joined(separator: ","))]\#(cursor)}"#
    }

    static func policy(
        screens: Int = 2, profiles: Int = 5, conversions: Int = 1, video: Bool = true, downloads: Bool = false,
        libraries: String = "null", quality: String = "1080p", permissions: String = "[]", requests: Bool = true
    ) -> String {
        #"{"all_libraries":\#(libraries == "null"),"library_ids":\#(libraries),"playback_allowed":true,"max_streams":\#(screens),"#
            + #""max_profiles":\#(profiles),"transcode_allowed":\#(video),"max_transcodes":\#(conversions),"download_allowed":\#(downloads),"#
            + #""download_transcode_allowed":false,"max_playback_quality":"\#(quality)","allowed_permissions":\#(permissions),"requests_allowed":\#(requests)}"#
    }

    static func entitlement(
        key: String = "family", revision: Int = 3, group: String? = nil, slots: Int = 8, transcodes: Int = 2,
        reconciled: String? = "2026-11-12T09:30:00.123456Z"
    ) -> String {
        let group = group.map { #"{"id":9,"name":"Family plan","policy":\#($0)}"# } ?? "null"
        let reconciled = reconciled.map { #""\#($0)""# } ?? "null"
        return #"{"template_key":"\#(key)","template_revision":\#(revision),"managed_default_group":\#(group),"#
            + #""tenant_limits":{"slots":\#(slots),"transcodes":\#(transcodes)},"library_ids":null,"last_reconciled_at":\#(reconciled),"#
            + #""audit_history_href":"/api/bloem/v2/admin/platform/organizations/\#(orgID)/entitlement/audit"}"#
    }

    static func template(key: String, name: String, revision: Int, policy: String = policy()) -> String {
        #"{"key":"\#(key)","name":"\#(name)","revision":\#(revision),"enabled":true,"archived":false,"status":"enabled","policy":\#(policy),"created_at":"2026-11-01T10:00:00Z"}"#
    }

    static func templateList(_ rows: String...) -> String { #"{"templates":[\#(rows.joined(separator: ","))]}"# }

    static func dryRun(
        key: String = "premium", revision: Int = 2, changed: Bool = true, previousKey: String = "family", previousRevision: Int = 3,
        policy: String = policy(screens: 4), token: String = "dry.run.token"
    ) -> String {
        let change = changed
            ? #"[{"field":"template_revision","before":{"template_key":"\#(previousKey)","template_revision":\#(previousRevision)},"after":{"template_key":"\#(key)","template_revision":\#(revision)}}]"#
            : "[]"
        return #"{"result":{"organization_id":"\#(orgID)","template_key":"\#(key)","template_revision":\#(revision),"group_id":9,"dry_run":true,"#
            + #""changed":\#(changed),"profiles_moved":0,"previous_template_key":"\#(previousKey)","previous_template_revision":\#(previousRevision),"policy":\#(policy)},"#
            + #""template_key":"\#(key)","template_revision":\#(revision),"changed":\#(changed),"dry_run_token":"\#(token)","confirmation_token":"\#(token)","#
            + #""expires_at":"2026-11-13T12:10:00Z","changes":\#(change),"warnings":[]}"#
    }

    static func applied(key: String = "premium", revision: Int = 2) -> String {
        #"{"organization_id":"\#(orgID)","template_key":"\#(key)","template_revision":\#(revision),"group_id":9,"dry_run":false,"changed":true,"#
            + #""profiles_moved":3,"previous_template_key":"family","previous_template_revision":3,"policy":\#(policy(screens: 4))}"#
    }

    static func error(_ code: String, message: String = "Refused") -> String { #"{"error":"\#(code)","message":"\#(message)"}"# }
}
