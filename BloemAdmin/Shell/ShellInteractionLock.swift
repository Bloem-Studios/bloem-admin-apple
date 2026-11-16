import Observation
import SwiftUI

/// Counts the things (a dialog, a confirmation, a busy action) that must keep the shell still: while any
/// holds a lease the menu, search, context dropdown and sideways swipe are off, so the page cannot change
/// under it. System sheets and alerts already block touches on iOS; this covers inline states a page
/// wants to protect, like Android's `ShellInteractionLock`.
@Observable
@MainActor
final class ShellInteractionLock {
    private(set) var leaseCount = 0

    var isLocked: Bool { leaseCount > 0 }

    @MainActor
    final class Lease {
        private weak var lock: ShellInteractionLock?
        private var released = false

        fileprivate init(lock: ShellInteractionLock) {
            self.lock = lock
        }

        /// Releasing twice is harmless.
        func release() {
            guard !released else { return }
            released = true
            lock?.leaseCount -= 1
        }
    }

    func acquire() -> Lease {
        leaseCount += 1
        return Lease(lock: self)
    }
}

private struct ShellInteractionLockKey: EnvironmentKey {
    static var defaultValue: ShellInteractionLock? { nil }
}

extension EnvironmentValues {
    /// The shell's lock; nil where there is no shell.
    var shellInteractionLock: ShellInteractionLock? {
        get { self[ShellInteractionLockKey.self] }
        set { self[ShellInteractionLockKey.self] = newValue }
    }
}

private struct ShellInteractionLockModifier: ViewModifier {
    let active: Bool
    @Environment(\.shellInteractionLock) private var lock
    @State private var lease: ShellInteractionLock.Lease?

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, isActive in
                lease?.release()
                lease = isActive ? lock?.acquire() : nil
            }
            .onDisappear {
                lease?.release()
                lease = nil
            }
    }
}

extension View {
    /// Keeps the shell still (no page change, menu, search or context change) while `active` is true.
    func shellInteractionLocked(_ active: Bool) -> some View {
        modifier(ShellInteractionLockModifier(active: active))
    }
}
