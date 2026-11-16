import SwiftUI

/// The sign-in options a server offers, as Form sections: one "Sign in with <name>" button per
/// native OAuth provider (Authentik first and the one accent button, then the others as secondary buttons), then
/// the username and password fields when the server takes a password. Shared by Add Server and re-login.
struct SignInOptionsSections: View {
    let providers: AuthProviderCollection
    let rememberedProviderID: String?
    let controller: ProviderSignInController
    let isDisabled: Bool
    @Binding var username: String
    @Binding var password: String
    let onProvider: (AuthProvider) -> Void
    /// Shown as a Sign In button under the password fields; nil leaves signing in to the parent's toolbar.
    var onPassword: (() -> Void)?

    var body: some View {
        let oauth = providers.nativeOAuth(remembered: rememberedProviderID)
        if !oauth.isEmpty {
            Section {
                ForEach(Array(oauth.enumerated()), id: \.element.id) { index, provider in
                    providerButton(
                        provider,
                        prominent: index == 0 && (provider.isAuthentik || provider.isDefault || provider.id == rememberedProviderID)
                    )
                }
            }
        }
        if providers.passwordLogin {
            Section("Admin login") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                if let onPassword {
                    Button {
                        onPassword()
                    } label: {
                        Text("Sign in")
                    }
                    .disabled(isDisabled || controller.isConnecting || username.isEmpty || password.isEmpty)
                }
            }
        }
        if oauth.isEmpty && !providers.passwordLogin {
            Section {
                Text("This server's sign-in options aren't available in this app.")
                    .foregroundStyle(.bloemMuted)
            }
        }
    }

    @ViewBuilder
    private func providerButton(_ provider: AuthProvider, prominent: Bool) -> some View {
        let label = HStack {
            Text("Sign in with \(provider.displayName)")
            if controller.providerID == provider.id {
                Spacer()
                ProgressView()
            }
        }
        let button = Button { onProvider(provider) } label: { label }
            .disabled(isDisabled || controller.isConnecting)
        if prominent {
            button.buttonStyle(.bloemProminent)
        } else {
            button.buttonStyle(.bloemSecondary)
        }
    }
}

/// Re-login sections for one saved server: reads its sign-in options, then shows them. Used by the
/// single-server gate and the All Servers sheet. No "Change server": the server is fixed.
struct ReLoginSections: View {
    let server: AdminServer
    let store: ServerStore
    let viewModel: AdminGateViewModel
    let sessionState: AdminSessionState
    var onSuccess: () -> Void = {}

    private enum Phase {
        case loading
        case upgradeRequired
        case ready(ServerDiscovery)
    }

    @State private var phase = Phase.loading
    @State private var controller = ProviderSignInController(browser: SystemOAuthBrowserSession())
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoggingIn = false

    /// The provider the server was last signed in with, read from the store so a sign-in made after
    /// this view's `server` snapshot still counts.
    private var rememberedProviderID: String? {
        store.servers.first { $0.id == server.id }?.signInProviderID ?? server.signInProviderID
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                Section {
                    HStack {
                        ProgressView()
                        Text("Checking sign-in options…")
                    }
                }
            case .upgradeRequired:
                Section {
                    Text("This server needs a newer version of Bloem Admin.")
                        .foregroundStyle(.bloemDanger)
                    Button("Try again") {
                        phase = .loading
                        Task { await discover() }
                    }
                }
            case .ready(let discovery):
                SignInOptionsSections(
                    providers: discovery.providers,
                    rememberedProviderID: rememberedProviderID,
                    controller: controller,
                    isDisabled: isLoggingIn,
                    username: $username,
                    password: $password,
                    onProvider: { signIn(with: $0, discovery: discovery) },
                    onPassword: { Task { await signInWithPassword() } }
                )
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.bloemDanger) }
                }
            }
        }
        // No onDisappear: the system browser covering this screen can send it and would cancel the
        // sign-in just opened. The controller cancels itself when this view's state is released.
        .task(id: server.id) { await discover() }
    }

    private func discover() async {
        switch await AdminLogin.discoverForReLogin(server: server) {
        case .success(let discovery): phase = .ready(discovery)
        case .failure: phase = .upgradeRequired
        }
    }

    private func signInWithPassword() async {
        errorMessage = nil
        isLoggingIn = true
        defer { isLoggingIn = false }
        // reLoginAndResetSession clears the mid-session-401 flag (if that's what routed us here) on
        // success, scoped to THIS server only.
        errorMessage = await viewModel.reLoginAndResetSession(
            username: username, password: password, server: server, store: store, sessionState: sessionState
        )
        if errorMessage == nil { onSuccess() }
    }

    private func signIn(with provider: AuthProvider, discovery: ServerDiscovery) {
        errorMessage = nil
        let browser = controller.browser
        controller.start(
            provider: provider,
            work: {
                await viewModel.reLogin(
                    provider: provider, discovery: discovery, browser: browser,
                    server: server, store: store, sessionState: sessionState
                )
            },
            onResult: { outcome in
                switch outcome {
                case .signedIn: onSuccess()
                case .cancelled: break
                case .failed(let message): errorMessage = message
                }
            }
        )
    }
}
