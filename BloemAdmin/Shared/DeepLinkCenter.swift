import Foundation
import Observation

/// Holds the link that is waiting for a window. Whatever receives a link (`onOpenURL`, a notification
/// tap, a quick action, an App Intent) puts it here; the signed-in app takes it once the app lock is open
/// (`DeepLinkHandling`), so a link never opens a page behind the lock.
@MainActor
@Observable
final class DeepLinkCenter {
    static let shared = DeepLinkCenter()

    private(set) var pending: DeepLinkRoute?

    init() {}

    /// Keeps the route `url` names. False, and nothing kept, for a URL that is not one of ours.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard let route = DeepLinkRoute(url: url) else { return false }
        pending = route
        return true
    }

    func submit(_ route: DeepLinkRoute) {
        pending = route
    }

    /// The waiting route, which is then no longer waiting.
    func take() -> DeepLinkRoute? {
        defer { pending = nil }
        return pending
    }
}
