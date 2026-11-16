import SwiftUI

/// What every All servers page shows while no server is saved: the one place besides Manage servers where
/// Add Server appears.
struct NoServersView: View {
    let onAddServer: () -> Void

    var body: some View {
        BloemEmptyState {
            Label("No servers", icon: .server)
        } description: {
            Text("Add a Silo server to manage it here")
        } actions: {
            Button("Add server", action: onAddServer)
                .buttonStyle(.bloemProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("server-list-add-server")
        }
    }
}
