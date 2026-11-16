import Foundation

private struct ResendBody: Encodable {}

extension APIClient {
    private static func invitationPath(_ id: String, _ suffix: String = "") -> String {
        "/api/v2/admin/invitations/\(APIPath.segment(id))\(suffix)"
    }

    /// Every page of `GET /api/v2/admin/invitations` (declares only `limit` and `cursor`).
    func listInvitations() async throws -> [Invitation] {
        try await readAllPages("/api/v2/admin/invitations")
    }

    /// `POST /api/v2/admin/invitations`. The 201 carries the only copy of the claim link.
    func createInvitation(_ request: CreateInvitationRequest) async throws -> InvitationDelivery {
        try await post("/api/v2/admin/invitations", body: request)
    }

    /// `POST /api/v2/admin/invitations/{id}/resend`. The body is required; `{}` keeps the default delivery.
    func resendInvitation(id: String) async throws -> InvitationDelivery {
        try await post(Self.invitationPath(id, "/resend"), body: ResendBody())
    }

    /// `DELETE /api/v2/admin/invitations/{id}` answers 204.
    func revokeInvitation(id: String) async throws {
        try await delete(Self.invitationPath(id))
    }
}
