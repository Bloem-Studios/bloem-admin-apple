import Foundation

/*
 The words the web's admin uses for policy: plans, cohorts, access checks and bulk results
 (web/src/components/admin/policy/policyVocabulary.ts). One place per mapping, so a code reads the same on every
 page. A code the app does not know comes back as nil and the caller shows it as sentence-cased words.
 */

enum OrganizationVocabulary {
    /// Why one account in a bulk change was skipped or failed.
    static func resultReason(_ reason: String) -> String? {
        switch reason {
        case "already_applied": String(localized: "already had these settings")
        case "no_profiles": String(localized: "has no profiles")
        case "not_found": String(localized: "no longer exists")
        case "protected_owner": String(localized: "is the organization owner and can't be changed here")
        case "mutation_failed": String(localized: "couldn't be saved")
        case "authorization_state_changed": String(localized: "changed while this ran")
        case "actor_authority_target": String(localized: "skipped so you keep your own admin access")
        case "stale": String(localized: "changed after you chose")
        case "not_suspended": String(localized: "isn't suspended")
        case "target_protected": String(localized: "is protected from this change (an administrator, the owner, or yourself)")
        default: nil
        }
    }

    /// The reason as a phrase, whatever the code.
    static func resultReasonText(_ reason: String) -> String {
        resultReason(reason) ?? sentenceCase(reason)
    }

    /// The heading of a finished or running bulk change, as the web words it.
    static func bulkHeading(_ job: BulkJob) -> String {
        let notChanged = job.skipped.count + job.failed.count
        if job.status == "completed" && notChanged > 0 {
            return job.succeeded == 0 ? String(localized: "Nobody was changed") : String(localized: "Some people were changed")
        }
        switch job.status {
        case "queued": return String(localized: "Waiting to start")
        case "running": return String(localized: "Changing people…")
        case "completed": return String(localized: "Done")
        case "failed": return String(localized: "Stopped")
        case "cancelled": return String(localized: "Cancelled")
        default: return String(localized: "Changing people…")
        }
    }

    /// What a check was about ("Library access check"); unknown actions read as sentence-cased words.
    static func accessAction(_ action: String) -> String? {
        switch action {
        case "silo.permission.decision", "data.silo.permission.decision": String(localized: "Permission check")
        case "silo.scope.decision", "data.silo.scope.decision", "library_access_check": String(localized: "Library access check")
        case "silo.action.decision", "data.silo.action.decision": String(localized: "Playback or download check")
        case "data.silo.slow.decision": String(localized: "Check")
        case "playback_admission": String(localized: "Start playback")
        case "direct_play": String(localized: "Play")
        case "transcode": String(localized: "Convert video")
        case "audio_transcode": String(localized: "Convert audio")
        case "download": String(localized: "Download")
        case "download_transcode": String(localized: "Download a converted copy")
        default: nil
        }
    }

    static func accessActionText(_ action: String) -> String {
        accessAction(action) ?? sentenceCase(action)
    }

    /// Why a check was refused. An empty code is "No reason recorded".
    static func accessReason(_ code: String) -> String? {
        switch code {
        case "": String(localized: "No reason recorded")
        case "custom_denial": String(localized: "A custom rule refused it")
        case "unknown_permission": String(localized: "The permission isn't known")
        case "user_disabled": String(localized: "The account is disabled")
        case "admin_role_required": String(localized: "Only administrators can do this")
        case "primary_profile_required": String(localized: "Only the household's main profile can do this")
        case "marker_edit_permission_required": String(localized: "Needs permission to edit intro and credits markers")
        case "metadata_curation_permission_required": String(localized: "Needs permission to edit metadata")
        case "item_outside_user_libraries": String(localized: "The title is in a library they can't use")
        case "unknown_action": String(localized: "The action isn't known")
        case "downloads_disabled": String(localized: "Downloads are switched off on this server")
        case "download_permission_required": String(localized: "Their settings don't allow downloads")
        case "transcode_disabled", "transcoding_disabled": String(localized: "Video conversion is switched off")
        case "audio_transcoding_disabled": String(localized: "Audio conversion is switched off")
        case "download_transcode_permission_required": String(localized: "Their settings don't allow converted downloads")
        case "download_artifacts_unavailable": String(localized: "No downloadable copy is ready yet")
        case "quality_ceiling_exceeded": String(localized: "Above their best allowed picture quality")
        case "content_rating_exceeded": String(localized: "Above the profile's age rating")
        case "max_streams_exceeded": String(localized: "Every screen they're allowed was already in use")
        case "max_transcodes_exceeded": String(localized: "Every conversion they're allowed was already in use")
        default: nil
        }
    }

    static func accessReasonText(_ code: String) -> String {
        accessReason(code) ?? sentenceCase(code)
    }

    /// How a cohort came to be.
    static func derivation(_ kind: String) -> String? {
        switch kind {
        case "exact_template": String(localized: "From a plan")
        case "policy_patch": String(localized: "Changed from another cohort")
        case "managed_default": String(localized: "Organization default")
        default: nil
        }
    }

    static func derivationText(_ kind: String) -> String {
        derivation(kind) ?? sentenceCase(kind)
    }

    /// The best picture quality a policy allows, as the web words it.
    static func quality(_ quality: String) -> String? {
        switch quality {
        case "": String(localized: "Any quality")
        case "original": String(localized: "Original quality")
        case "1080p": String(localized: "Up to 1080p")
        case "2160p": String(localized: "Up to 4K")
        default: nil
        }
    }

    static func qualityText(_ value: String) -> String {
        quality(value) ?? sentenceCase(value)
    }

    /// A permission an access group or cohort can grant.
    static func permission(_ permission: String) -> String? {
        switch permission {
        case GroupPermissions.liveTV: String(localized: "Watch live TV")
        case GroupPermissions.metadata: String(localized: "Edit metadata")
        case GroupPermissions.markers: String(localized: "Edit intro and credits markers")
        default: nil
        }
    }

    static func permissionText(_ value: String) -> String {
        permission(value) ?? sentenceCase(value)
    }

    /// What the audit log's action codes say, in the web's words.
    static func auditAction(_ action: String) -> String? {
        switch action {
        case "organization.created": String(localized: "Organization created")
        case "organization.renamed": String(localized: "Renamed")
        case "organization.slug_changed": String(localized: "Short name changed")
        case "organization.suspended": String(localized: "Suspended")
        case "organization.reactivated": String(localized: "Reactivated")
        case "organization.ownership_transferred": String(localized: "Ownership transferred")
        case "organization.entitlement_applied": String(localized: "Plan applied")
        case "membership.created": String(localized: "Member added")
        case "membership.role_changed": String(localized: "Member's role changed")
        case "membership.status_changed": String(localized: "Member suspended or reactivated")
        case "entitlement.policy_assignment": String(localized: "Plan or settings changed for an account")
        case "people.bulk_job_created": String(localized: "Bulk change started")
        case "people.bulk_policy_job_created": String(localized: "Bulk plan or settings change started")
        case "people.bulk_job_completed": String(localized: "Bulk change finished")
        case "people.bulk_job_failed": String(localized: "Bulk change failed")
        case "people.bulk_job_cancelled": String(localized: "Bulk change stopped")
        case "people.bulk_group_assigned": String(localized: "Profiles moved to an access group")
        case "people.bulk_policy_assigned": String(localized: "Account moved to a new plan or settings")
        case "people.bulk_membership_suspended": String(localized: "Member suspended in a bulk change")
        case "people.bulk_membership_reactivated": String(localized: "Member reactivated in a bulk change")
        case "people.bulk_record_skipped": String(localized: "An account was skipped in a bulk change")
        case "people.bulk_record_failed": String(localized: "An account failed in a bulk change")
        case "people.membership_updated": String(localized: "Membership changed")
        case "people.profile_group_updated": String(localized: "Profile moved to another access group")
        case "people.password_reset_issued": String(localized: "Password reset link issued")
        case "people.sessions_revoked": String(localized: "Signed out everywhere")
        case "people.session_revoked": String(localized: "Signed out of one session")
        case "people.device_signed_out": String(localized: "Signed out of a device")
        case "people.profile_created": String(localized: "Profile added")
        case "people.profile_renamed": String(localized: "Profile renamed")
        case "people.profile_pin_cleared": String(localized: "Profile PIN cleared")
        case "people.profile_removed": String(localized: "Profile removed")
        case "stream.stopped": String(localized: "Stream stopped")
        case "stream.message_sent": String(localized: "Message sent to a stream")
        case "support_access.opened": String(localized: "Platform support opened this organization")
        case "support_access.closed": String(localized: "Platform support closed its access")
        case "people.membership_update_refused": String(localized: "Membership change refused")
        case "people.profile_group_update_refused": String(localized: "Access group move refused")
        case "people.password_reset_refused": String(localized: "Password reset refused")
        case "people.sessions_revoke_refused", "people.session_revoke_refused", "people.device_sign_out_refused":
            String(localized: "Sign-out refused")
        case "people.profile_create_refused", "people.profile_rename_refused", "people.profile_pin_clear_refused",
             "people.profile_remove_refused":
            String(localized: "Profile change refused")
        case "stream.stop_refused", "stream.message_refused": String(localized: "Stream action refused")
        default: nil
        }
    }

    // MARK: Support refusals

    /// Why the server refused a support action, in words: who is protected and why, what the account or the server
    /// cannot do, or that a budget is spent. Nil for any other answer, which the caller words as before.
    static func supportRefusal(_ error: APIError) -> String? {
        switch (error.statusCode, error.code ?? "") {
        case (409, "target_protected"): return protectedReason(error.reason)
        case (409, "membership_not_active"):
            return String(localized: "Their membership isn't active (it's invited or suspended), so this can't be done.")
        case (409, "account_shared"):
            return String(localized: "This account belongs to more than one organization, so it can't be changed from here.")
        case (409, "password_login_disabled"):
            return String(localized: "This person signs in through another provider and has no password to reset.")
        case (409, "account_disabled"): return String(localized: "This account is disabled.")
        case (409, "email_unavailable"):
            return String(localized: "This person has no email address to send a reset link to. Create a link to hand over instead.")
        case (409, "capability_not_configured"):
            return error.capability == "email"
                ? String(localized: "This server can't send email. Create a link to hand over instead.")
                : String(localized: "This server can't make reset links yet: it has no public address")
        case (409, "name_conflict"): return String(localized: "Another of their profiles already has that name")
        case (409, "primary_profile_protected"): return String(localized: "The household's main profile can't be removed")
        case (422, "profile_limit_reached"): return String(localized: "They already have as many profiles as they're allowed")
        case (409, "stale_sequence"): return String(localized: "Another command reached this stream first. Try again.")
        case (409, "realtime_unavailable"): return String(localized: "This player isn't connected, so it can't show a message")
        case (409, "idempotency_conflict"): return String(localized: "That message was already sent with different text. Write it again.")
        case (429, "rate_limited"): return rateLimited(retryAfter: error.retryAfter)
        case (503, "dependency_unavailable"):
            return String(localized: "The change took effect, but a connected service hasn't been told yet. Try again shortly to finish it.")
        default: return nil
        }
    }

    /// `409 target_protected`: the server's table of who may act on whom.
    static func protectedReason(_ reason: String?) -> String {
        switch reason {
        case "self":
            String(localized: "You can't do this to your own account. Change your own password or sign out in the app.")
        case "platform_account":
            String(localized: "This is a server operator's account. It can't be changed from an organization.")
        case "organization_owner":
            String(localized: "This person is the organization's owner. Only the platform operator can help the owner.")
        case "organization_admin":
            String(localized: "This person is an administrator. Only the organization's owner can help another administrator.")
        default:
            String(localized: "This person is protected from this action")
        }
    }

    /// `429 rate_limited`, with the wait from `Retry-After` (seconds) when the server sent it.
    static func rateLimited(retryAfter: String?) -> String {
        guard let seconds = retryAfter.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), seconds > 0 else {
            return String(localized: "Too many support actions in a short time. Wait a few minutes and try again.")
        }
        let minutes = max(1, Int((Double(seconds) / 60).rounded(.up)))
        if minutes == 1 { return String(localized: "Too many support actions in a short time. Try again in a minute.") }
        return String(localized: "Too many support actions in a short time. Try again in \(minutes) minutes.")
    }

    static func auditActionText(_ action: String) -> String {
        auditAction(action) ?? sentenceCase(action)
    }

    /// An outcome other than success; `success` and an empty outcome say nothing.
    static func auditOutcome(_ outcome: String) -> String? {
        switch outcome {
        case "partial_failure": String(localized: "Some not changed")
        case "conflict": String(localized: "Not changed")
        case "failed", "failure": String(localized: "Failed")
        case "skipped": String(localized: "Skipped")
        case "denied": String(localized: "Refused")
        default: nil
        }
    }

    /// `people.bulk_job_created` is not a sentence; this is the fallback for any code the app has no words for.
    static func sentenceCase(_ code: String) -> String {
        let words = code
            .replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return code }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
