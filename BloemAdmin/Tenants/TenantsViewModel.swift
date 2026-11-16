import Foundation
import Observation

/// Read-only — this screen has no mutating actions at all (no freeze/thaw,
/// no create/delete, no limits editing). Tenant lifecycle/entitlements are
/// an automated billing-system contract, not something an admin edits by
/// hand from here; that was an explicit product decision, not an oversight.
@Observable
@MainActor
final class TenantsViewModel {
    private(set) var tenants: [Tenant] = []
    /// Reserved for `load()` failures only, mirroring every other list
    /// screen's errorMessage/actionErrorMessage split — there's no
    /// "action" here, but `members`/`membersErrorMessage` below need their
    /// OWN failure slot distinct from this one so a failed member-list
    /// fetch on the detail screen doesn't blank the tenant list underneath.
    private(set) var errorMessage: String?
    private(set) var members: [TenantMember] = []
    private(set) var membersErrorMessage: String?
    private(set) var hasLoadedTenants = false
    private(set) var hasLoadedMembers = false
    private var membersRequestID = 0
    private var selectedTenantID: String?

    var tenantsPresentation: CollectionPresentation {
        .resolve(hasLoaded: hasLoadedTenants, itemCount: tenants.count, errorMessage: errorMessage)
    }

    var membersPresentation: CollectionPresentation {
        .resolve(hasLoaded: hasLoadedMembers, itemCount: members.count, errorMessage: membersErrorMessage)
    }

    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        defer { hasLoadedTenants = true }
        do {
            let loaded = try await client.tenants()
            tenants = loaded
            errorMessage = nil
        } catch let error as APIError {
            if let sessionState, let message = sessionState.handleAuthenticationFailure(error) {
                errorMessage = message
            } else {
                errorMessage = error.message
            }
        } catch {
            errorMessage = String(localized: "Organizations couldn't be loaded. Try again.")
        }
    }

    func loadMembers(tenantID: String, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        membersRequestID += 1
        let requestID = membersRequestID
        selectedTenantID = tenantID
        members = []
        membersErrorMessage = nil
        hasLoadedMembers = false

        do {
            let loaded = try await client.tenantMembers(tenantID: tenantID)
            guard requestID == membersRequestID, selectedTenantID == tenantID else { return }
            members = loaded
            membersErrorMessage = nil
            hasLoadedMembers = true
        } catch let error as APIError {
            guard requestID == membersRequestID, selectedTenantID == tenantID else { return }
            if let sessionState, let message = sessionState.handleAuthenticationFailure(error) {
                membersErrorMessage = message
            } else {
                membersErrorMessage = error.message
            }
            hasLoadedMembers = true
        } catch {
            guard requestID == membersRequestID, selectedTenantID == tenantID else { return }
            membersErrorMessage = String(localized: "Members couldn't be loaded. Try again.")
            hasLoadedMembers = true
        }
    }
}
