import Foundation
import SwiftUI

/// What the app is looking at: every saved server at once, or one of them.
enum ShellScope: Equatable, Hashable, Sendable {
    case allServers
    case server(String)

    /// The scope the app opens in. All servers when it was the last choice, when nothing was chosen, or
    /// when the chosen server is no longer saved.
    static func start(allServers: Bool, selectedServerID: String?, savedIDs: Set<String>) -> ShellScope {
        if !allServers, let selectedServerID, savedIDs.contains(selectedServerID) {
            return .server(selectedServerID)
        }
        return .allServers
    }
}

/// The last scope the person picked, kept on this device (not a secret).
struct ShellScopePreferences {
    static let allServersKey = "bloem.admin.scope.allServers"
    static let selectedServerKey = "bloem.admin.scope.selectedServerID"

    // UserDefaults is thread-safe but not declared Sendable; this is only used on the main actor.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var allServers: Bool {
        defaults.object(forKey: Self.allServersKey) as? Bool ?? true
    }

    var selectedServerID: String? {
        defaults.string(forKey: Self.selectedServerKey)
    }

    func startScope(savedIDs: Set<String>) -> ShellScope {
        ShellScope.start(allServers: allServers, selectedServerID: selectedServerID, savedIDs: savedIDs)
    }

    func remember(_ scope: ShellScope) {
        switch scope {
        case .allServers:
            defaults.set(true, forKey: Self.allServersKey)
        case .server(let id):
            defaults.set(false, forKey: Self.allServersKey)
            defaults.set(id, forKey: Self.selectedServerKey)
        }
    }

    func reset() {
        defaults.removeObject(forKey: Self.allServersKey)
        defaults.removeObject(forKey: Self.selectedServerKey)
    }
}

/// A saved server as the context dropdown lists it.
struct ScopeOption: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

/// HOOK FOR ORGANIZATION MODE. An organization the signed-in account administers on `serverID`, listed
/// under that server in the context dropdown. Nothing fills this in yet: the app passes an empty list
/// and a no-op selection callback until organization mode is wired in (see `ScopeControl`).
struct ScopeOrganization: Equatable, Identifiable, Hashable, Sendable {
    let serverID: String
    let organizationID: String
    let displayName: String

    var id: String { serverID + "/" + organizationID }
}

/// One line of the context dropdown.
struct ContextDropdownItem: Equatable, Identifiable {
    enum Kind: Equatable {
        case allServers
        case server(String)
        case organization(ScopeOrganization)
    }

    let kind: Kind
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    /// Organizations sit indented under their server.
    let isIndented: Bool

    var id: String {
        switch kind {
        case .allServers: "all-servers"
        case .server(let id): "server:" + id
        case .organization(let organization): "organization:" + organization.id
        }
    }
}

/// What the context dropdown shows, as plain values so it can be tested without a view: All servers,
/// then each saved server with the organizations listed under it.
struct ContextDropdownModel: Equatable {
    var allServers: Bool
    var selectedServerID: String?
    var servers: [ScopeOption]
    /// Hook for organization mode. Empty by default.
    var organizations: [ScopeOrganization] = []
    /// Set while an organization is open; its server's own entry is then not the selected one.
    var selectedOrganizationID: String?

    /// The button's name: what is being looked at.
    var title: String {
        if allServers { return String(localized: "All servers") }
        if let selectedOrganizationID,
           let organization = organizations.first(where: {
               $0.organizationID == selectedOrganizationID && $0.serverID == selectedServerID
           }) {
            return organization.displayName
        }
        return servers.first { $0.id == selectedServerID }?.displayName ?? String(localized: "All servers")
    }

    var items: [ContextDropdownItem] {
        var result = [
            ContextDropdownItem(
                kind: .allServers,
                title: String(localized: "All servers"),
                isSelected: allServers,
                isEnabled: !servers.isEmpty,
                isIndented: false
            )
        ]
        for server in servers {
            result.append(ContextDropdownItem(
                kind: .server(server.id),
                title: server.displayName,
                isSelected: !allServers && selectedOrganizationID == nil && selectedServerID == server.id,
                isEnabled: true,
                isIndented: false
            ))
            for organization in organizations where organization.serverID == server.id {
                result.append(ContextDropdownItem(
                    kind: .organization(organization),
                    title: organization.displayName,
                    isSelected: selectedOrganizationID == organization.organizationID && selectedServerID == server.id,
                    isEnabled: true,
                    isIndented: true
                ))
            }
        }
        return result
    }
}

/// The context dropdown and what choosing in it does.
struct ScopeControl {
    var model: ContextDropdownModel
    var onSelectAllServers: () -> Void
    var onSelectServer: (String) -> Void
    /// HOOK FOR ORGANIZATION MODE: called when an organization listed under a server is chosen.
    /// Empty by default; the integrator supplies it together with `model.organizations`.
    var onSelectOrganization: (ScopeOrganization) -> Void = { _ in }
    /// Opens the switcher sheet: the top bar's "Name ⌄" button.
    var onOpenSwitcher: () -> Void = {}

    func select(_ item: ContextDropdownItem) {
        switch item.kind {
        case .allServers: onSelectAllServers()
        case .server(let id): onSelectServer(id)
        case .organization(let organization): onSelectOrganization(organization)
        }
    }
}

private struct ScopeControlKey: EnvironmentKey {
    static var defaultValue: ScopeControl? { nil }
}

extension EnvironmentValues {
    /// The context dropdown for every screen under the shell's root. Nil in previews and tests of one screen.
    var scopeControl: ScopeControl? {
        get { self[ScopeControlKey.self] }
        set { self[ScopeControlKey.self] = newValue }
    }
}
