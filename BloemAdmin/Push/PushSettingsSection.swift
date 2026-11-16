import SwiftUI

/// The "Notifications" part of App settings, as Form sections: what each saved server can send to this phone,
/// and a switch per kind. A plain Silo server says plainly that push is not available there, with no error.
struct PushSettingsSection: View {
    @Bindable var model: PushSettingsModel

    var body: some View {
        Section {
            if model.offersPermissionButton {
                Text("Allow notifications to receive these")
                    .foregroundStyle(.bloemMuted)
                    .accessibilityIdentifier("push-permission-needed")
                Button("Allow notifications") { Task { await model.allowNotifications() } }
                    .accessibilityIdentifier("push-allow")
            }
            if model.showsPermissionHelp {
                Text("Notifications are off for this app in iOS Settings")
                    .foregroundStyle(.bloemMuted)
                    .accessibilityIdentifier("push-permission-denied")
                Text("Open iOS Settings, tap Notifications, then turn on Allow Notifications")
                    .foregroundStyle(.bloemMuted)
                Button("Open iOS Settings") { model.openSystemSettings() }
                    .accessibilityIdentifier("push-open-settings")
            }
            if model.servers.isEmpty {
                Text("No servers saved")
                    .foregroundStyle(.bloemMuted)
                    .accessibilityIdentifier("push-no-servers")
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("A server can notify you when something is broken or waiting on you. Switch each kind on or off per server")
        }

        ForEach(model.servers) { server in
            Section {
                Text(PushSettingsModel.text(for: model.status(server)))
                    .foregroundStyle(.bloemMuted)
                    .accessibilityIdentifier("push-status-\(server.id)")
                ForEach(model.kinds(for: server)) { kind in
                    Toggle(
                        kind.settingsLabel,
                        isOn: Binding(
                            get: { model.isOn(kind, server: server) },
                            set: { on in Task { await model.set(kind, on: on, server: server) } }
                        )
                    )
                    .accessibilityIdentifier("push-\(server.id)-\(kind.rawValue)")
                }
            } header: {
                Text(server.displayName)
            }
        }
    }
}
