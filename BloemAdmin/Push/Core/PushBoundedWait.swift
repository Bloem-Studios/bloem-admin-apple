import Foundation

/// Runs `work` and gives up on it after `budget`, answering nil. Used wherever a push path must not hang on a
/// server that does not answer: the extension's text fetch and the unregister on sign-out. `work` should honour
/// cancellation (URLSession's async calls do), because the group waits for it to end.
enum PushBoundedWait {
    static func run<T: Sendable>(_ budget: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
