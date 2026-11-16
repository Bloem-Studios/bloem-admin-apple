import Observation
import SwiftUI

/// Add Server in two steps: the address (the server is read for its name, identity and sign-in
/// providers), then the sign-in options that server offers.
@Observable
@MainActor
final class AddServerFlow {
    enum Step: Equatable {
        case server
        case signIn(ServerDiscovery)
    }

    private(set) var step: Step = .server
    private(set) var errorMessage: String?
    private(set) var isBusy = false
    private(set) var didAddServer = false
    let signIn: ProviderSignInController

    /// How long typing must pause before a finished-looking address is checked by itself.
    static let autoCheckPause: Duration = .milliseconds(700)

    @ObservationIgnored private let store: ServerStore
    @ObservationIgnored private let session: URLSession?
    @ObservationIgnored private let makeID: () -> String
    @ObservationIgnored private let pause: @Sendable () async throws -> Void
    @ObservationIgnored private var autoCheck: Task<Void, Never>?
    /// Bumped by every edit and every check, so only the latest check's answer is used.
    @ObservationIgnored private var checkGeneration = 0

    init(
        store: ServerStore,
        browser: any OAuthBrowserSession,
        session: URLSession? = nil,
        makeID: @escaping () -> String = { UUID().uuidString },
        pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: AddServerFlow.autoCheckPause) }
    ) {
        self.store = store
        self.session = session
        self.makeID = makeID
        self.pause = pause
        self.signIn = ProviderSignInController(browser: browser)
    }

    /// Step one: the address field changed. A check in flight is dropped, and a finished-looking
    /// address is checked by itself once typing pauses, so no tap is needed.
    func addressChanged(_ address: String) {
        dropCheck()
        errorMessage = nil
        guard ServerEndpointValidator.isFinishedAddress(address) else { return }
        let pause = pause
        // Weak: a sheet dismissed during the pause releases the flow, and the check then does nothing.
        autoCheck = Task { [weak self] in
            do { try await pause() } catch { return }
            guard !Task.isCancelled else { return }
            await self?.check(address)
        }
    }

    /// Step one: Continue (or Go) checks at once, including addresses that are not checked by
    /// themselves, such as an IP address.
    func continueToSignIn(address: String) async {
        dropCheck()
        await check(address)
    }

    private func check(_ address: String) async {
        guard step == .server else { return }
        checkGeneration += 1
        let generation = checkGeneration
        errorMessage = nil
        isBusy = true
        let result = await AdminLogin.discover(address: address, session: session)
        guard generation == checkGeneration else { return }
        isBusy = false
        switch result {
        case .success(let discovery): step = .signIn(discovery)
        case .failure(let failure): errorMessage = failure.message(providerName: nil)
        }
    }

    private func dropCheck() {
        autoCheck?.cancel()
        autoCheck = nil
        checkGeneration += 1
        isBusy = false
    }

    /// Back to step one; a waiting browser sign-in is cancelled.
    func changeServer() {
        signIn.cancel()
        errorMessage = nil
        step = .server
    }

    func connect(username: String, password: String) async {
        guard case .signIn(let discovery) = step, !isBusy, !signIn.isConnecting else { return }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        switch await AdminLogin.signInWithPassword(discovery: discovery, username: username, password: password, session: session) {
        case .success(let signedIn): add(discovery, signedIn)
        case .failure(let failure): errorMessage = failure.message(providerName: nil)
        }
    }

    func connect(with provider: AuthProvider) {
        guard case .signIn(let discovery) = step, !isBusy else { return }
        errorMessage = nil
        let session = session
        let browser = signIn.browser
        signIn.start(
            provider: provider,
            work: {
                await AdminLogin.signInWithProvider(
                    discovery: discovery,
                    provider: provider,
                    browser: browser,
                    session: session
                )
            },
            onResult: { [weak self] result in
                switch result {
                case .success(let signedIn): self?.add(discovery, signedIn)
                case .failure(let failure): self?.errorMessage = failure.message(providerName: provider.displayName)
                }
            }
        )
    }

    private func add(_ discovery: ServerDiscovery, _ signedIn: SignedIn) {
        let server = AdminServer(
            id: makeID(),
            baseURL: discovery.baseURL,
            displayName: discovery.displayName,
            signInProviderID: signedIn.providerID
        )
        do {
            try store.addServer(server, credentials: signedIn.credentials)
            didAddServer = true
        } catch {
            errorMessage = String(localized: "Could not save this server on this device.")
        }
    }
}

struct AddServerView: View {
    let store: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var flow: AddServerFlow
    @State private var urlText = ""
    @State private var username = ""
    @State private var password = ""

    init(store: ServerStore) {
        self.store = store
        _flow = State(initialValue: AddServerFlow(store: store, browser: SystemOAuthBrowserSession()))
    }

    var body: some View {
        NavigationStack {
            Form {
                switch flow.step {
                case .server:
                    Section("Server") {
                        // Typing a finished address moves on by itself; Go checks at once. The field
                        // stays editable while a check runs, and an edit drops it.
                        TextField("your-server.example.com", text: $urlText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit {
                                guard !urlText.isEmpty else { return }
                                Task { await flow.continueToSignIn(address: urlText) }
                            }
                            .onChange(of: urlText) { _, address in flow.addressChanged(address) }
                    }
                case .signIn(let discovery):
                    Section("Server") {
                        Text(discovery.displayName)
                        Button("Change server") { flow.changeServer() }
                    }
                    SignInOptionsSections(
                        providers: discovery.providers,
                        rememberedProviderID: nil,
                        controller: flow.signIn,
                        isDisabled: flow.isBusy,
                        username: $username,
                        password: $password,
                        onProvider: { flow.connect(with: $0) }
                    )
                }
                if let errorMessage = flow.errorMessage {
                    Text(errorMessage).foregroundStyle(.bloemDanger)
                }
            }
            .navigationTitle("Add a Silo server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        flow.signIn.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    switch flow.step {
                    case .server:
                        Button("Continue") { Task { await flow.continueToSignIn(address: urlText) } }
                            .disabled(flow.isBusy || urlText.isEmpty)
                    case .signIn(let discovery):
                        if discovery.providers.passwordLogin {
                            Button("Connect") { Task { await flow.connect(username: username, password: password) } }
                                .disabled(flow.isBusy || flow.signIn.isConnecting || username.isEmpty || password.isEmpty)
                        }
                    }
                }
            }
            .onChange(of: flow.didAddServer) { _, added in
                if added { dismiss() }
            }
            // No onDisappear: the system browser covering this sheet can send it. Cancel and Change
            // server cancel explicitly; dismissing the sheet releases the flow, whose controller
            // cancels in deinit.
        }
    }
}
