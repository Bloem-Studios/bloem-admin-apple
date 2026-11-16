import Foundation

/// An `AdminInvitation` from `/api/v2/admin/invitations`. Required on the wire: id, email,
/// delivery, role, library_ids (nullable), create_profile, show_tour, note, invited_by,
/// invited_by_name, status, expires_at and created_at. IDs are strings.
struct Invitation: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    /// Empty for a pending invitation created as a link.
    let email: String
    /// `link`, `email_sent`, `email_unconfirmed` or `unknown`.
    let delivery: String
    let role: String
    let accessGroupID: String?
    /// nil inherits library access; an empty array is an explicit empty override.
    let libraryIDs: [String]?
    let createProfile: Bool
    let showTour: Bool
    let note: String
    let invitedBy: String
    let invitedByName: String
    /// `pending`, `accepted`, `revoked` or `expired`, shown as the server sends it.
    let status: String
    let expiresAt: Date
    let acceptedAt: Date?
    let acceptedUserID: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, email, delivery, role, note, status
        case accessGroupID = "access_group_id"
        case libraryIDs = "library_ids"
        case createProfile = "create_profile"
        case showTour = "show_tour"
        case invitedBy = "invited_by"
        case invitedByName = "invited_by_name"
        case expiresAt = "expires_at"
        case acceptedAt = "accepted_at"
        case acceptedUserID = "accepted_user_id"
        case createdAt = "created_at"
    }

    var isPending: Bool { status == "pending" }
}

/// Body of `POST /api/v2/admin/invitations`: only what the form exposes. `delivery` is left out
/// so the server emails when it can and otherwise returns the link; the rest take server defaults.
struct CreateInvitationRequest: Encodable, Sendable {
    let email: String
    let role: String
    let note: String?
}

/// `InvitationDelivery`, the response to create and resend (both 201). `claim_url` is a one-time
/// disclosure that carries the bearer claim token and is never returned again.
struct InvitationDelivery: Decodable, Identifiable, Equatable, Sendable {
    let claimURL: String
    let deliveryStatus: String
    let invitation: Invitation

    enum CodingKeys: String, CodingKey {
        case claimURL = "claim_url"
        case deliveryStatus = "delivery_status"
        case invitation
    }

    var id: String { invitation.id }

    /// The link to show, or nil if the server sent an empty one.
    var claimLink: String? { claimURL.isEmpty ? nil : claimURL }

    /// `sent`: the server emailed the link.
    var emailSent: Bool { deliveryStatus == "sent" }

    /// The admin must not assume an email arrived. `sent`, `not_configured` (no email on this
    /// server) and `not_requested` (a link invitation) are understood non-failures; anything
    /// else, `failed_or_unknown` or a value this app does not know, is flagged.
    var deliveryFailed: Bool {
        !["sent", "not_configured", "not_requested"].contains(deliveryStatus)
    }
}
