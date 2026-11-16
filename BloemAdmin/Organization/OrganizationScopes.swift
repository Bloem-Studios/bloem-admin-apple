import Foundation

/// The organizations the context dropdown lists under each saved server: every organization context the
/// server's account may administer (`discoverAdminContexts`), in server order, then the server's own order.
/// The platform context is the server's own entry, so it is not repeated.
enum OrganizationScopes {
    static func list(servers: [AdminServer], contexts: [String: [AdminContext]]) -> [ScopeOrganization] {
        servers.flatMap { server in
            (contexts[server.id] ?? []).compactMap { context -> ScopeOrganization? in
                guard context.scope == .organization, let organizationID = context.organizationID else { return nil }
                return ScopeOrganization(serverID: server.id, organizationID: organizationID, displayName: context.name)
            }
        }
    }

    /// The context an open organization runs under, if the server still lists it.
    static func context(serverID: String, organizationID: String, in contexts: [String: [AdminContext]]) -> AdminContext? {
        contexts[serverID]?.first { $0.scope == .organization && $0.organizationID == organizationID }
    }
}
