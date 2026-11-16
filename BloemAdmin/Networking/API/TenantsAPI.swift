import Foundation

// Platform routes. They need the platform pass (`POST /api/bloem/v2/admin/session`), which the
// app does not obtain yet, so nothing calls them while the Tenants tab is hidden.
extension APIClient {
    /// `GET /api/bloem/v2/admin/platform/tenants`: a bare array, not a v2 list envelope.
    func tenants() async throws -> [Tenant] {
        try await get("/api/bloem/v2/admin/platform/tenants")
    }

    /// `GET /api/bloem/v2/admin/platform/tenants/{tenant_id}/members`: a bare array.
    func tenantMembers(tenantID: String) async throws -> [TenantMember] {
        try await get("/api/bloem/v2/admin/platform/tenants/\(APIPath.segment(tenantID))/members")
    }
}
