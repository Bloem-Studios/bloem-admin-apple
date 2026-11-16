import Foundation

/// Words for the codes servers send, so a screen never shows `direct_stream` or `admin` raw. One place,
/// in the interface language, written the way the web admin words them. A code the app doesn't know is
/// shown as plain sentence-case text rather than dropped.
enum Vocabulary {
    /// "owner", "admin" and "user" as a person would say them.
    static func role(_ raw: String) -> String {
        switch raw.lowercased() {
        case "owner": String(localized: "Owner")
        case "admin", "administrator": String(localized: "Administrator")
        case "user": String(localized: "User")
        case "member": String(localized: "Member")
        default: sentenceCase(raw)
        }
    }

    /// A scheduled task's state.
    static func taskState(_ raw: String) -> String {
        switch raw.lowercased() {
        case "idle": String(localized: "Idle")
        case "running": String(localized: "Running")
        case "queued", "pending": String(localized: "Queued")
        case "disabled": String(localized: "Disabled")
        case "failed", "error": String(localized: "Failed")
        case "cancelled", "canceled": String(localized: "Cancelled")
        default: sentenceCase(raw)
        }
    }

    /// An invitation's status.
    static func invitationStatus(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pending": String(localized: "Pending")
        case "accepted": String(localized: "Accepted")
        case "revoked": String(localized: "Revoked")
        case "expired": String(localized: "Expired")
        default: sentenceCase(raw)
        }
    }

    /// A member's status on a server's organization list.
    static func memberStatus(_ raw: String) -> String {
        switch raw.lowercased() {
        case "active": String(localized: "Active")
        case "suspended": String(localized: "Suspended")
        case "invited": String(localized: "Invited")
        default: sentenceCase(raw)
        }
    }

    /// "device_name" and "DEVICE NAME" read "Device name"; anything already readable keeps its case.
    static func sentenceCase(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = spaced.first else { return "" }
        let rest = spaced.dropFirst()
        let shouting = spaced == spaced.uppercased() && spaced.contains(where: \.isLetter)
        return first.uppercased() + (shouting ? rest.lowercased() : String(rest))
    }

    /// "User 42", "Group 7", "Library 3": one way to name something by its number, with no "#".
    static func numbered(_ noun: LocalizedStringResource, _ id: some CustomStringConvertible) -> String {
        "\(String(localized: noun)) \(id)"
    }
}
