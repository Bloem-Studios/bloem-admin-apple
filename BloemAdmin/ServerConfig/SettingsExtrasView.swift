import SwiftUI

/// What a page offers besides its settings: tests that answer "is it broken?", each ending in a clear
/// pass or fail with the server's reason.
struct SettingsExtrasView: View {
    let page: SettingsPage
    let model: ServerSettingsModel
    let client: APIClient
    let sessionState: ServerScopedSession?
    let tests: SettingsTestRunners

    var body: some View {
        ForEach(Array(page.extras.enumerated()), id: \.offset) { _, extra in
            switch extra {
            case .emailTest:
                EmailTestSection(model: model, client: client, sessionState: sessionState, runner: tests.runner("email"))
            case .connectionCheck(let kind, let keys):
                ConnectionCheckSection(
                    kind: kind, keys: keys, model: model, client: client, sessionState: sessionState,
                    runner: tests.runner("check.\(kind)")
                )
            case .serverChannels:
                ServerChannelsSection(client: client, sessionState: sessionState, serverName: model.serverName, tests: tests)
            case .signInProviders:
                SignInProvidersSection(client: client, sessionState: sessionState, serverName: model.serverName, tests: tests)
            }
        }
    }
}

/// The answer of a test, as a pass or fail line and the server's words.
struct TestResultView: View {
    let state: SettingsTestState
    var identifier: String = "settings.testResult"

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                Text("Testing")
                    .foregroundStyle(.bloemMuted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
        case .finished(let outcome):
            VStack(alignment: .leading, spacing: 4) {
                Label(outcome.verdict, icon: outcome.passed ? .circleCheck : .octagonX)
                    .bloemText(.titleSmall)
                if !outcome.detail.isEmpty {
                    Text(outcome.detail)
                        .bloemText(.bodySmall)
                        .foregroundStyle(.bloemMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(outcome.steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(step.label, icon: step.passed ? .check : .x)
                            .bloemText(.bodySmall)
                        if !step.message.isEmpty {
                            Text(step.message)
                                .bloemText(.bodySmall)
                                .foregroundStyle(.bloemMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
        case .failed(let message):
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Could not run the test").bloemText(.titleSmall)
                    Text(message).bloemText(.bodySmall).foregroundStyle(.bloemMuted).fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                IconImage(.triangleAlert, size: .row)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: Email

private struct EmailTestSection: View {
    let model: ServerSettingsModel
    let client: APIClient
    let sessionState: ServerScopedSession?
    let runner: SettingsTestRunner
    @State private var recipient = ""

    private var address: String { recipient.trimmingCharacters(in: .whitespaces) }
    private var looksLikeAddress: Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !address.contains(" ")
    }

    var body: some View {
        Section {
            TextField("Send the test to", text: $recipient)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.emailTest.recipient")
            Button {
                Task { await runner.run(sessionState: sessionState) { try await client.sendTestEmail(to: address) } }
            } label: {
                Text("Send test email")
            }
            .disabled(runner.state.isRunning || !looksLikeAddress)
            .accessibilityIdentifier("settings.emailTest.send")
            TestResultView(state: runner.state, identifier: "settings.emailTest.result")
        } header: {
            Text("Test")
        } footer: {
            Text(model.hasUnsavedEdits
                ? LocalizedStringKey("Save your changes first. The test uses the saved mail settings")
                : LocalizedStringKey("Sends one real message through the saved mail settings"))
        }
    }
}

// MARK: Connection check

private struct ConnectionCheckSection: View {
    let kind: String
    let keys: [String]
    let model: ServerSettingsModel
    let client: APIClient
    let sessionState: ServerScopedSession?
    let runner: SettingsTestRunner

    var body: some View {
        Section {
            Button {
                let dirty = model.dirtyKeys(in: keys)
                let values = Dictionary(uniqueKeysWithValues: dirty.map { ($0, model.drafts[$0] ?? "") })
                Task { await runner.run(sessionState: sessionState) { try await client.checkConnection(kind: kind, values: values, dirtyKeys: dirty) } }
            } label: {
                Text("Check connection")
            }
            .disabled(runner.state.isRunning)
            .accessibilityIdentifier("settings.check.\(kind)")
            TestResultView(state: runner.state, identifier: "settings.check.\(kind).result")
        } header: {
            Text("Test")
        } footer: {
            Text("Checks the values above, saved or not, from the server")
        }
    }
}

// MARK: Server channels

private struct ServerChannelsSection: View {
    let client: APIClient
    let sessionState: ServerScopedSession?
    let serverName: String?
    let tests: SettingsTestRunners
    @State private var channels: [NotificationServerChannel]?
    @State private var loadError: String?

    var body: some View {
        Section {
            if let channels {
                if channels.isEmpty {
                    Text("No server channels are set up. Add one on the web admin")
                        .foregroundStyle(.bloemMuted)
                }
                ForEach(channels) { channel in
                    ServerChannelRow(channel: channel, client: client, sessionState: sessionState, runner: tests.runner("channel.\(channel.id)"))
                }
            } else if let loadError {
                Label(loadError, icon: .triangleAlert)
                Button("Try again") { Task { await load() } }
            } else {
                ProgressView()
            }
        } header: {
            Text("Server channels")
        } footer: {
            Text("Test sends one sample message to the channel")
        }
        .task { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            channels = try await client.notificationServerChannels()
        } catch {
            loadError = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "Could not load the server channels. Try again"), serverName: serverName
            )
        }
    }
}

private struct ServerChannelRow: View {
    let channel: NotificationServerChannel
    let client: APIClient
    let sessionState: ServerScopedSession?
    let runner: SettingsTestRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name).bloemText(.bodyLarge)
                    Text(subtitle).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                Spacer()
                Button("Test") {
                    Task { await runner.run(sessionState: sessionState) { try await client.testServerChannel(id: channel.id) } }
                }
                .buttonStyle(.bloemSecondary)
                .disabled(runner.state.isRunning)
                .accessibilityIdentifier("settings.channel.\(channel.id).test")
            }
            if let failure = lastFailure {
                Text(failure).bloemText(.bodySmall).foregroundStyle(.bloemMuted).fixedSize(horizontal: false, vertical: true)
            }
            TestResultView(state: runner.state, identifier: "settings.channel.\(channel.id).result")
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = [channel.type.isEmpty ? "" : ServerStatus.humanize(channel.type), channel.urlHost].filter { !$0.isEmpty }
        parts.append(channel.enabled ? String(localized: "On") : String(localized: "Off"))
        return parts.joined(separator: " · ")
    }

    private var lastFailure: String? {
        guard channel.consecutiveFailures > 0 || channel.disabledReason != nil else { return nil }
        var text = channel.lastFailureMessage ?? channel.disabledReason ?? String(localized: "The last post failed")
        if let at = channel.lastFailureAt {
            text += " · " + at.formatted(date: .abbreviated, time: .shortened)
        }
        return String(localized: "Last failure: \(text)")
    }
}

// MARK: Sign-in providers

private struct SignInProvidersSection: View {
    let client: APIClient
    let sessionState: ServerScopedSession?
    let serverName: String?
    let tests: SettingsTestRunners
    @State private var providers: [SignInProvider]?
    @State private var loadError: String?

    var body: some View {
        Section {
            if let providers {
                if providers.isEmpty {
                    Text("No single sign-on plugin is installed")
                        .foregroundStyle(.bloemMuted)
                }
                ForEach(providers) { provider in
                    SignInProviderRow(provider: provider, client: client, sessionState: sessionState, runner: tests.runner("provider.\(provider.id)"))
                }
            } else if let loadError {
                Label(loadError, icon: .triangleAlert)
                Button("Try again") { Task { await load() } }
            } else {
                ProgressView()
            }
        } header: {
            Text("Single sign-on providers")
        } footer: {
            Text("The test asks the provider to confirm its saved connection. Setup stays on the web admin")
        }
        .task { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            providers = try await client.signInProviders()
        } catch {
            loadError = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "Could not load the sign-in providers. Try again"), serverName: serverName
            )
        }
    }
}

private struct SignInProviderRow: View {
    let provider: SignInProvider
    let client: APIClient
    let sessionState: ServerScopedSession?
    let runner: SettingsTestRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.name)
                    Text(provider.enabled ? LocalizedStringKey("On") : LocalizedStringKey("Off")).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                Spacer()
                Button("Test connection") {
                    Task { await runner.run(sessionState: sessionState) { try await client.testSignInProvider(provider) } }
                }
                .buttonStyle(.bloemSecondary)
                .disabled(runner.state.isRunning)
                .accessibilityIdentifier("settings.provider.\(provider.id).test")
            }
            TestResultView(state: runner.state, identifier: "settings.provider.\(provider.id).result")
        }
        .padding(.vertical, 4)
    }
}
