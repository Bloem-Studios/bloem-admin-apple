import SwiftUI

/// The "Server alerts" part of App settings, as Form sections. Everything is off until the admin turns the
/// master switch on; that is also the moment iOS asks for notification permission.
struct ServerAlertsSection: View {
    @Bindable var model: AlertSettingsModel

    var body: some View {
        Section {
            Toggle(
                "Alert when a server stops answering",
                isOn: Binding(
                    get: { model.isOn },
                    set: { on in Task { await model.setEnabled(on) } }
                )
            )
            .accessibilityIdentifier("alerts-master-switch")

            if model.permission == .denied {
                Text("Notifications are off for this app in iOS Settings")
                    .foregroundStyle(.bloemMuted)
                    .accessibilityIdentifier("alerts-permission-denied")
                Button("Open iOS Settings") { model.openSystemSettings() }
                    .accessibilityIdentifier("alerts-open-settings")
            }
        } header: {
            Text("Server alerts")
        } footer: {
            Text("iOS decides how often background checks run")
        }

        if model.isOn {
            Section {
                ForEach(model.servers) { server in
                    Toggle(
                        server.displayName,
                        isOn: Binding(
                            get: { model.isServerOn(server.id) },
                            set: { model.setServer(server.id, enabled: $0) }
                        )
                    )
                    .accessibilityIdentifier("alerts-server-\(server.id)")
                }
            } header: {
                Text("Servers to watch")
            } footer: {
                Text("Checks only ask each server whether it is up and need no sign-in")
            }

            Section {
                Toggle(
                    "Show details on the lock screen",
                    isOn: Binding(
                        get: { model.showsDetails },
                        set: { model.setShowsDetails($0) }
                    )
                )
                .accessibilityIdentifier("alerts-details-switch")
            } footer: {
                Text("Off shows only the server's name; this setting is for this device")
            }
        }
    }
}
