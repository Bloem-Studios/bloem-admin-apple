import SwiftUI

/// Manage servers, laid out like one of the web admin's settings pages: a title, then grouped lists — All
/// servers and the saved servers (each with its address and whether this device is signed in to it, and
/// Rename, Forget credentials and Remove in its menu). It opens from the drawer's foot. Add Server stays at
/// the bottom; it also appears in the switcher and on the empty All servers pages.
struct ManageServersView: View {
    let store: ServerStore
    let sessionState: AdminSessionState
    let onOpenAllServers: () -> Void
    let onOpenServer: (AdminServer) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingAddServer = false
    @State private var serverPendingRename: AdminServer?
    @State private var pendingAction: ServerAction?
    @State private var persistenceErrorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SettingsRow(
                        title: String(localized: "All servers"),
                        subtitle: String(localized: "View and manage every added server at once"),
                        icon: .layers,
                        tint: Theme.muted,
                        action: {
                            dismiss()
                            onOpenAllServers()
                        }
                    )
                    .accessibilityIdentifier("server-list-all-servers")
                }
                Section {
                    if store.servers.isEmpty {
                        Text("No individual servers saved yet")
                            .foregroundStyle(.bloemMuted)
                    }
                    ForEach(store.servers) { server in
                        ServerRow(
                            server: server,
                            signedIn: isSignedIn(server),
                            onOpen: {
                                dismiss()
                                onOpenServer(server)
                            },
                            onRename: { serverPendingRename = server },
                            onForget: { pendingAction = .forget(server) },
                            onRemove: { pendingAction = .remove(server) }
                        )
                    }
                } header: {
                    Text("Saved servers")
                }
            }
            .listStyle(.insetGrouped)
            .bloemPageBackground()
            .navigationTitle("Manage servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        IconImage(.chevronLeft, size: .bar)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(String(localized: "Back"))
                    .accessibilityIdentifier("server-list-back")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showingAddServer = true
                } label: {
                    Label("Add server", icon: .plus)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bloemProminent)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.surface)
                .accessibilityIdentifier("server-list-add-server")
            }
        }
        .sheet(isPresented: $showingAddServer) {
            AddServerView(store: store)
        }
        .sheet(item: $serverPendingRename) { server in
            RenameServerView(server: server, store: store)
        }
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            switch action {
            case .forget(let server):
                Button("Forget credentials", role: .destructive) {
                    do {
                        try store.signOut(server.id, sessionState: sessionState)
                    } catch {
                        persistenceErrorMessage = error.localizedDescription
                    }
                    pendingAction = nil
                }
            case .remove(let server):
                Button("Remove server", role: .destructive) {
                    do {
                        try store.removeServer(server.id, sessionState: sessionState)
                    } catch {
                        persistenceErrorMessage = error.localizedDescription
                    }
                    pendingAction = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(action.message)
        }
        .alert(
            "Saved data couldn't be updated",
            isPresented: Binding(
                get: { persistenceErrorMessage != nil },
                set: { if !$0 { persistenceErrorMessage = nil } }
            )
        ) {
            Button("Done", role: .cancel) { persistenceErrorMessage = nil }
        } message: {
            Text(persistenceErrorMessage ?? "")
        }
    }

    /// Reads the Keychain again whenever any sign-in changes (`credentialRevision`), so the state shown here
    /// is never stale.
    private func isSignedIn(_ server: AdminServer) -> Bool {
        _ = store.credentialRevision
        return store.accessToken(for: server.id) != nil
    }
}

/// A destructive action on a saved server that waits for a confirmation.
private enum ServerAction {
    case forget(AdminServer)
    case remove(AdminServer)

    var title: String {
        switch self {
        case .forget(let server): String(localized: "Forget credentials for \(server.displayName)?")
        case .remove(let server): String(localized: "Remove \(server.displayName)?")
        }
    }

    var message: String {
        switch self {
        case .forget:
            String(localized: "This removes the locally stored access and refresh tokens from this device. It does not revoke server-side sessions.")
        case .remove:
            String(localized: "This removes the server and its stored sign-in from this device. You can add it again later.")
        }
    }
}

/// One row of a settings group: at least 44pt tall, tappable as a whole.
private struct SettingsRow: View {
    let title: String
    let subtitle: String
    let icon: BloemIcon
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconImage(icon, size: .row)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).bloemText(.titleMedium)
                    Text(subtitle).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                Spacer(minLength: 0)
                IconImage(.chevronRight, size: .inline)
                    .foregroundStyle(.bloemMuted)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A saved server: its name, address and sign-in state. Tapping the row opens the server; the menu holds
/// Rename, Forget credentials and Remove.
private struct ServerRow: View {
    let server: AdminServer
    let signedIn: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onForget: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    // A dot only for what needs a look: a server that is signed out, or insecure.
                    Circle()
                        .fill(statusColor ?? Color.clear)
                        .frame(width: StatusLabel.dotSize, height: StatusLabel.dotSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.displayName)
                            .bloemText(.titleMedium)
                            .lineLimit(1)
                        Text(server.baseURL.absoluteString)
                            .bloemText(.bodySmall)
                            .foregroundStyle(.bloemMuted)
                            .lineLimit(1)
                        if server.usesInsecureAddress {
                            Text("This server uses an insecure address. Remove it and add its HTTPS address.")
                                .bloemText(.bodySmall)
                                .foregroundStyle(.bloemDanger)
                        } else if !signedIn {
                            Text("Signed out")
                                .bloemText(.bodySmall)
                                .foregroundStyle(.bloemWarn)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(server.usesInsecureAddress)
            .accessibilityIdentifier("server-row:" + server.id)

            Menu {
                Button("Rename", action: onRename)
                Button("Forget credentials", action: onForget)
                    .disabled(!signedIn)
                Button("Remove server", role: .destructive, action: onRemove)
            } label: {
                RowActionsIcon()
            }
            .accessibilityLabel(String(localized: "Actions for \(server.displayName)"))
            .accessibilityIdentifier("server-actions:" + server.id)
        }
    }

    private var statusColor: Color? {
        if server.usesInsecureAddress { return Theme.danger }
        return signedIn ? nil : Theme.warn
    }
}

/// Small modal for editing an already-added server's `displayName`. Mirrors
/// `MessageSessionView`'s "small form as a modal" shape (NavigationStack +
/// Form + cancel/confirm toolbar actions) — there's no networking involved,
/// so it writes straight through to `store.renameServer` on Save.
private struct RenameServerView: View {
    let server: AdminServer
    let store: ServerStore
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var persistenceErrorMessage: String?

    init(server: AdminServer, store: ServerStore) {
        self.server = server
        self.store = store
        _displayName = State(initialValue: server.displayName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Server name", text: $displayName)
                }
                if let persistenceErrorMessage {
                    Text(persistenceErrorMessage)
                        .foregroundStyle(.bloemDanger)
                }
            }
            .navigationTitle("Rename server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes") {
                        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            do {
                                try store.renameServer(server.id, to: trimmed)
                                dismiss()
                            } catch {
                                persistenceErrorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
