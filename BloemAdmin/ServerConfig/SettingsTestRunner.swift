import Foundation
import Observation

/// Where one test action stands: not run, running, or answered. A test that ran and failed is
/// `.finished` with `passed` false (the server's reason in `message`); `.failed` is a test that could
/// not run at all (no connection, signed out).
enum SettingsTestState: Equatable, Sendable {
    case idle
    case running
    case finished(TestOutcome)
    case failed(String)

    var isRunning: Bool { self == .running }
}

/// Runs one test action (send a test email, check a connection, test a channel or sign-in provider) and
/// keeps its answer for the page to show. Nothing is retried: a test that reaches a provider may send
/// mail or bill, so a second run is the person's decision.
@Observable
@MainActor
final class SettingsTestRunner {
    private(set) var state: SettingsTestState = .idle
    let serverName: String?

    init(serverName: String? = nil) {
        self.serverName = serverName
    }

    func run(sessionState: ServerScopedSession? = nil, _ operation: () async throws -> TestOutcome) async {
        guard !state.isRunning else { return }
        state = .running
        do {
            state = .finished(try await operation())
        } catch {
            state = .failed(ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "The test could not run. Check your connection and try again"),
                serverName: serverName
            ))
        }
    }

    func reset() {
        guard !state.isRunning else { return }
        state = .idle
    }
}

/// The test runners of one settings page, made on first use and kept while the page is open.
@Observable
@MainActor
final class SettingsTestRunners {
    private var runners: [String: SettingsTestRunner] = [:]
    let serverName: String?

    init(serverName: String? = nil) {
        self.serverName = serverName
    }

    func runner(_ id: String) -> SettingsTestRunner {
        if let existing = runners[id] { return existing }
        let created = SettingsTestRunner(serverName: serverName)
        runners[id] = created
        return created
    }
}

extension TestOutcome {
    /// "Passed", or "Failed", for the label of a result.
    var verdict: String {
        passed ? String(localized: "Passed") : String(localized: "Failed")
    }

    /// The server's words, with how long it took when it said.
    var detail: String {
        var parts: [String] = []
        if !message.isEmpty { parts.append(message) }
        if let durationMS { parts.append(String(localized: "\(durationMS) ms")) }
        return parts.joined(separator: " · ")
    }
}
