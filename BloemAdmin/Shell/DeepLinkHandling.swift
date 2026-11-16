import SwiftUI

private struct AppIsLockedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the app lock covers this window. Set by the window's root, read by whatever must wait
    /// for the lock (`DeepLinkHandling`).
    var appIsLocked: Bool {
        get { self[AppIsLockedKey.self] }
        set { self[AppIsLockedKey.self] = newValue }
    }
}

/// Moves the shell to the page a waiting link names, once the app lock is open. A link that arrives while
/// the app is locked waits, and is applied when the lock clears; a link for a server that is not saved
/// is dropped.
private struct DeepLinkHandling: ViewModifier {
    let router: ShellRouter
    let savedServerIDs: Set<String>
    @Environment(\.appIsLocked) private var isLocked

    func body(content: Content) -> some View {
        content
            .onChange(of: DeepLinkCenter.shared.pending, initial: true) { applyPending() }
            .onChange(of: isLocked) { applyPending() }
    }

    @MainActor
    private func applyPending() {
        guard !isLocked, let route = DeepLinkCenter.shared.take() else { return }
        router.open(route, savedServerIDs: savedServerIDs)
    }
}

extension View {
    func deepLinkHandling(router: ShellRouter, savedServerIDs: Set<String>) -> some View {
        modifier(DeepLinkHandling(router: router, savedServerIDs: savedServerIDs))
    }
}
