import SwiftUI

/// The app's own Settings page, the drawer's "Settings" row. It is a page of the shell, not a dialog: the bar above it
/// is the shell's. Sections, in the shared order: Appearance, App lock, Notifications, About. The app lock is always on
/// here (the app holds administrator access), so it is shown, not switched.
struct AppSettingsView: View {
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system.rawValue
    @State private var alerts: AlertSettingsModel
    @State private var push: PushSettingsModel

    /// `servers` are the saved servers the "Server alerts" and "Notifications" sections list.
    init(servers: [AdminServer] = []) {
        let alerts = AlertRuntime.settingsModel(servers: servers)
        _alerts = State(initialValue: alerts)
        _push = State(initialValue: PushRuntime.settingsModel(servers: servers, alerts: alerts))
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .segmentedUnlessLargeText()
                .labelsHidden()
                .accessibilityIdentifier("appearance-picker")
            }
            Section {
                LabeledContent("Device unlock", value: String(localized: "Always on"))
            } header: {
                Text("App lock")
            } footer: {
                Text("Bloem Admin locks whenever you leave it and asks for Face ID, Touch ID or your device passcode when you come back. It cannot be turned off, because the app holds administrator access to your servers.")
            }
            ServerAlertsSection(model: alerts)
            PushSettingsSection(model: push)
            Section("About") {
                LabeledContent("Version", value: version)
            }
        }
        .accessibilityIdentifier("app-settings")
        .task { await alerts.load() }
        .task { await push.load() }
        .onReceive(NotificationCenter.default.publisher(for: .pushStatusDidChange)) { _ in push.reload() }
    }
}
