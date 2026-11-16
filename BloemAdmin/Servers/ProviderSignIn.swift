import Observation
import SwiftUI

/// The browser sign-in orchestration shared by Add Server and re-login: at most one provider sign-in
/// at a time. Starting another cancels the earlier one (and closes its browser) and waits for it to
/// finish, so only the latest sign-in ever reports a result.
@Observable
@MainActor
final class ProviderSignInController {
    let browser: any OAuthBrowserSession

    private(set) var isConnecting = false
    /// The provider a waiting sign-in uses.
    private(set) var providerID: String?
    /// The last provider tried, for the error copy.
    private(set) var providerName: String?

    @ObservationIgnored private let taskBox = TaskBox()
    @ObservationIgnored private var generation = 0

    /// Holds the running sign-in where `deinit` can reach it without main-actor isolation.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func swap(_ new: Task<Void, Never>?) -> Task<Void, Never>? {
            lock.withLock {
                let old = task
                task = new
                return old
            }
        }
    }

    init(browser: any OAuthBrowserSession) {
        self.browser = browser
    }

    /// Runs `work` as the one sign-in. `onResult` receives its value only when no later sign-in has
    /// started and this one was not cancelled.
    func start<Value: Sendable>(
        provider: AuthProvider,
        work: @escaping @MainActor () async -> Value,
        onResult: @escaping @MainActor (Value) -> Void = { _ in }
    ) {
        // Starting a sign-in never closes its own browser: only an earlier one is cancelled.
        let previous = taskBox.swap(nil)
        if let previous {
            previous.cancel()
            browser.cancel()
        }
        generation += 1
        let mine = generation
        isConnecting = true
        providerID = provider.id
        providerName = provider.displayName
        let running = Task { [weak self] in
            await previous?.value
            let result = await work()
            guard let self, self.generation == mine else { return }
            self.isConnecting = false
            self.providerID = nil
            if !Task.isCancelled { onResult(result) }
        }
        _ = taskBox.swap(running)
    }

    /// Cancels a waiting sign-in. Call it from explicit actions (Cancel, Change server). Do not tie it
    /// to `onDisappear`: the system browser covering the screen can trigger that and would cancel the
    /// sign-in it just opened. When the owner goes away for good, `deinit` cancels instead.
    func cancel() {
        taskBox.swap(nil)?.cancel()
        browser.cancel()
        generation += 1
        isConnecting = false
        providerID = nil
    }

    deinit {
        guard let running = taskBox.swap(nil) else { return }
        running.cancel()
        let browser = browser
        Task { @MainActor in browser.cancel() }
    }
}
