import Foundation

/// The status filter of the Organizations list, with the words the web uses (`list.anyStatus`, `active`, `suspended`,
/// `settingUp`).
enum PlatformOrganizationStatusFilter: CaseIterable, Identifiable, Hashable, Sendable {
    case all, active, suspended, settingUp

    var id: Self { self }

    /// The `status` the server filters on; nil for every status.
    var serverValue: String? {
        switch self {
        case .all: nil
        case .active: "active"
        case .suspended: "suspended"
        case .settingUp: "initializing"
        }
    }

    var title: String {
        switch self {
        case .all: String(localized: "Any status")
        case .active: String(localized: "Active")
        case .suspended: String(localized: "Suspended")
        case .settingUp: String(localized: "Setting up")
        }
    }
}

/// Words for the Organizations pages. A status is always said in words; an account number is never a name.
enum PlatformOrganizationText {
    static func status(_ status: String) -> String {
        switch status {
        case "active": String(localized: "Active")
        case "suspended": String(localized: "Suspended")
        case "initializing": String(localized: "Setting up")
        default: capitalised(status)
        }
    }

    static func membershipStatus(_ status: String) -> String {
        switch status {
        case "active": String(localized: "Active")
        case "suspended": String(localized: "Suspended")
        case "invited": String(localized: "Invited")
        default: capitalised(status)
        }
    }

    /// Owner, Administrator or Member: the organization's owner is the account the server names as owner.
    static func role(of member: PlatformMembership, ownerAccountID: Int64?) -> String {
        if let ownerAccountID, member.accountID == ownerAccountID { return String(localized: "Owner") }
        return member.isAdministrator ? String(localized: "Administrator") : String(localized: "Member")
    }

    /// "12 people · 25 profiles · 3 libraries" for a list row.
    static func counts(_ organization: OrganizationSummary) -> String {
        [
            OrganizationText.people(Int(organization.membershipCount)),
            OrganizationText.profiles(Int(organization.profileCount)),
            OrganizationText.libraries(Int(organization.libraryCount)),
        ].joined(separator: " · ")
    }

    /// What the confirmation says before an organization is suspended: who loses access, and that nothing is deleted.
    static func suspendConsequence(name: String, activeMembers: Int) -> String {
        switch activeMembers {
        case ..<1:
            String(localized: "Nobody is active in \(name) right now. Anyone who joins loses access until you reactivate it. Nothing is deleted.")
        case 1:
            String(localized: "1 active member loses access to \(name) until you reactivate it. Nothing is deleted.")
        default:
            String(localized: "\(activeMembers) active members lose access to \(name) until you reactivate it. Nothing is deleted.")
        }
    }

    static func reactivateConsequence(name: String) -> String {
        String(localized: "Members of \(name) can use it again.")
    }

    static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// `some_new_permission` as "Some new permission".
    static func humanised(_ code: String) -> String {
        capitalised(code.replacingOccurrences(of: "_", with: " "))
    }
}

/// What a plan setting counts: a screen is a stream, a conversion a transcode (the web's wording).
enum PolicyLimitNoun: Sendable {
    case screens, profiles, conversions
}

/// A plan's settings in the web's words (policyVocabulary.ts).
enum PolicyWords {
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
    }

    static func limit(_ value: Int, _ noun: PolicyLimitNoun) -> String {
        guard value != 0 else { return String(localized: "No limit") }
        switch noun {
        case .screens: return OrganizationText.screens(value)
        case .profiles: return OrganizationText.profiles(value)
        case .conversions: return OrganizationText.conversions(value)
        }
    }

    static func yesNo(_ value: Bool) -> String {
        value ? String(localized: "Yes") : String(localized: "No")
    }

    static func quality(_ code: String) -> String {
        switch code {
        case "": String(localized: "Any quality")
        case "original": String(localized: "Original quality")
        case "1080p": String(localized: "Up to 1080p")
        case "2160p": String(localized: "Up to 4K")
        default: code
        }
    }

    /// Library numbers stand in for names: the platform pass cannot read a customer's library list.
    static func libraries(_ ids: [Int]?) -> String {
        guard let ids else { return String(localized: "All libraries") }
        guard !ids.isEmpty else { return String(localized: "None") }
        return ids.map { String(localized: "Library \($0)") }.joined(separator: ", ")
    }

    static func permissions(_ codes: [String]?) -> String {
        guard let codes else { return String(localized: "All permissions") }
        guard !codes.isEmpty else { return String(localized: "None") }
        return codes.map(permission).joined(separator: ", ")
    }

    static func permission(_ code: String) -> String {
        switch code {
        case "metadata_curation": String(localized: "Edit metadata")
        case "marker_edit": String(localized: "Edit intro and credits markers")
        case "watch_live_tv": String(localized: "Watch Live TV")
        default: PlatformOrganizationText.humanised(code)
        }
    }

    /// Every setting of a plan, labelled as the web labels them.
    static func rows(_ policy: EntitlementPolicy) -> [Row] {
        [
            Row(label: String(localized: "Libraries"), value: libraries(policy.libraryIDs)),
            Row(label: String(localized: "Plays video"), value: yesNo(policy.playbackAllowed)),
            Row(label: String(localized: "Screens at once"), value: limit(policy.maxStreams, .screens)),
            Row(label: String(localized: "Profiles"), value: limit(policy.maxProfiles, .profiles)),
            Row(label: String(localized: "Video conversion"), value: yesNo(policy.transcodeAllowed)),
            Row(label: String(localized: "Conversions at once"), value: limit(policy.maxTranscodes, .conversions)),
            Row(label: String(localized: "Download original files"), value: yesNo(policy.downloadAllowed)),
            Row(label: String(localized: "Download converted copies"), value: yesNo(policy.downloadTranscodeAllowed)),
            Row(label: String(localized: "Best picture quality"), value: quality(policy.maxPlaybackQuality)),
            Row(label: String(localized: "Media requests"), value: yesNo(policy.requestsAllowed)),
            Row(label: String(localized: "Extra permissions"), value: permissions(policy.allowedPermissions)),
        ]
    }
}

/// What putting an organization on a plan changes, setting by setting, from the settings its members have now to the
/// settings the plan gives them.
enum PlanChangeSummary {
    struct Change: Equatable, Identifiable, Sendable {
        let label: String
        /// Nil when the organization had no settings from a plan yet.
        let before: String?
        let after: String

        var id: String { label }

        var sentence: String {
            if let before { return String(localized: "\(label) goes from \(before) to \(after)") }
            return String(localized: "\(label) becomes \(after)")
        }
    }

    /// The settings that differ. With no current settings every setting is new.
    static func changes(from current: EntitlementPolicy?, to new: EntitlementPolicy) -> [Change] {
        let after = PolicyWords.rows(new)
        guard let current else { return after.map { Change(label: $0.label, before: nil, after: $0.value) } }
        let before = Dictionary(uniqueKeysWithValues: PolicyWords.rows(current).map { ($0.label, $0.value) })
        return after.compactMap { row in
            guard let old = before[row.label], old != row.value else { return nil }
            return Change(label: row.label, before: old, after: row.value)
        }
    }

    /// "Family, revision 3 → Premium, revision 2".
    static func headline(from oldName: String?, fromRevision: Int64, to newName: String, toRevision: Int64) -> String {
        let old = oldName.map { String(localized: "\($0), revision \(fromRevision)") } ?? String(localized: "No plan yet")
        return "\(old) → " + String(localized: "\(newName), revision \(toRevision)")
    }
}
