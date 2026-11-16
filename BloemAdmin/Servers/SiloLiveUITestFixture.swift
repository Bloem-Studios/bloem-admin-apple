#if DEBUG
import SwiftUI

/// The UI-test seam for a gated live run against a real Silo server (`SiloServerLiveUITests`). Launched with
/// `--ui-testing-live-silo` and the environment variables `SILO_LIVE_URL`, `SILO_LIVE_USER` and `SILO_LIVE_PASSWORD`,
/// the app signs in to that server with the same discovery and password sign-in the Add server form runs, saves it, and
/// then opens as normal. The login is read from the environment of the run only: it is never in a launch argument, a
/// typed string the test runner logs, a file in the repository or a log line, and nothing here prints it. Compiled into
/// debug builds only.
enum SiloLiveUITestFixture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-live-silo")
    }

    struct Target {
        let address: String
        let username: String
        let password: String
    }

    static var target: Target? {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["SILO_LIVE_URL"], let username = environment["SILO_LIVE_USER"],
              let password = environment["SILO_LIVE_PASSWORD"],
              !address.isEmpty, !username.isEmpty, !password.isEmpty else { return nil }
        return Target(address: address, username: username, password: password)
    }
}

struct SiloLiveSeedRoot: View {
    private enum Phase: Equatable {
        case signingIn
        case ready
        case failed(String)
    }

    @State private var phase = Phase.signingIn

    var body: some View {
        switch phase {
        case .ready:
            AppRootView()
        case .signingIn:
            ProgressView("Signing in")
                .accessibilityIdentifier("silo-live-status")
                .task { await seed() }
        case .failed(let reason):
            Text(reason)
                .padding()
                .accessibilityIdentifier("silo-live-status")
        }
    }

    private func seed() async {
        guard let target = SiloLiveUITestFixture.target else {
            phase = .failed("The live server is not set (SILO_LIVE_URL, SILO_LIVE_USER, SILO_LIVE_PASSWORD).")
            return
        }
        switch await AdminLogin.discover(address: target.address) {
        case .failure(let failure):
            phase = .failed("Discovery failed: \(failure.message(providerName: nil) ?? "cancelled")")
        case .success(let discovery):
            switch await AdminLogin.signInWithPassword(discovery: discovery, username: target.username, password: target.password) {
            case .failure(let failure):
                phase = .failed("Sign-in failed: \(failure.message(providerName: nil) ?? "cancelled")")
            case .success(let signedIn):
                do {
                    let server = AdminServer(
                        id: UUID().uuidString, baseURL: discovery.baseURL, displayName: "Silo server", signInProviderID: signedIn.providerID
                    )
                    try ServerStore().addServer(server, credentials: signedIn.credentials)
                    phase = .ready
                } catch {
                    phase = .failed("The server could not be saved on this device.")
                }
            }
        }
    }
}
#endif
