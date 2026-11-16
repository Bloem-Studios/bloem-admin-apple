import SwiftUI

/// Read-only tenant visibility (Bloem-specific reseller/hosting feature). `AdminTabView` keeps
/// this screen out of the tab list until the app can obtain the platform pass that the tenant
/// routes need; the screen and its view model stay so it can come back.
struct TenantsListView: View {
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @State private var viewModel = TenantsViewModel()

    var body: some View {
        List(viewModel.tenants) { tenant in
            NavigationLink {
                TenantMembersView(tenant: tenant, client: client, viewModel: viewModel)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tenant.name).bloemText(.titleMedium)
                    Text("\(tenant.slotsUsageText) · \(tenant.transcodeLimitText)")
                        .bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                    if tenant.frozen {
                        Label(frozenTitle(for: tenant), icon: .snowflake)
                        .bloemText(.labelMedium)
                        .foregroundStyle(.bloemDanger)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .overlay {
            switch viewModel.tenantsPresentation {
            case .loading:
                ProgressView()
            case .failure:
                if let message = viewModel.errorMessage {
                    BloemEmptyState("Connection lost", icon: .wifiOff, description: Text(message))
                }
            case .empty:
                BloemEmptyState(
                    "No organizations",
                    icon: .building2,
                    description: Text("No organizations on this server")
                )
            case .content:
                EmptyView()
            }
        }
        .navigationTitle("Organizations")
        .liveRefresh(client: client, channels: []) {
            await viewModel.load(client: client, sessionState: sessionState)
        }
        .refreshable { await viewModel.load(client: client, sessionState: sessionState) }
    }

    private func frozenTitle(for tenant: Tenant) -> LocalizedStringKey {
        if let reason = tenant.frozenReason, !reason.isEmpty {
            return "Suspended: \(reason)"
        }
        return "Suspended"
    }
}

/// Member list for one tenant — also read-only, no actions.
struct TenantMembersView: View {
    let tenant: Tenant
    let client: APIClient
    let viewModel: TenantsViewModel
    @Environment(\.adminSessionState) private var sessionState

    var body: some View {
        List(viewModel.members) { member in
            VStack(alignment: .leading, spacing: 4) {
                Text(member.username).bloemText(.titleMedium)
                Text(member.email).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                StatusLabel(Vocabulary.memberStatus(member.status), tone: member.status == "suspended" ? .warning : .normal)
            }
            .accessibilityElement(children: .combine)
        }
        .overlay {
            switch viewModel.membersPresentation {
            case .loading:
                ProgressView()
            case .failure:
                if let message = viewModel.membersErrorMessage {
                    BloemEmptyState("Connection lost", icon: .wifiOff, description: Text(message))
                }
            case .empty:
                BloemEmptyState(
                    "No members",
                    icon: .users,
                    description: Text("This organization has no members")
                )
            case .content:
                EmptyView()
            }
        }
        .navigationTitle(tenant.name)
        .task { await viewModel.loadMembers(tenantID: tenant.id, client: client, sessionState: sessionState) }
        .refreshable { await viewModel.loadMembers(tenantID: tenant.id, client: client, sessionState: sessionState) }
    }
}
