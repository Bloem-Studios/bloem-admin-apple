import Foundation

/// What an organization page does with the organization live socket (docs/design.md).
@MainActor
enum OrganizationLive {
    /// Keeps an organization page current, until the task is cancelled (the page went away).
    ///
    /// With the socket (`OrganizationSession.offersLive`) the page reads when it opens and again each time the socket
    /// says its `channel` changed; there is no timer. The socket opens only while a page that shows a channel is in
    /// front and the app is in the foreground, and closes shortly after.
    ///
    /// Without it (a server that has not got the feature) the page does exactly what it did before: `legacy`. The same
    /// goes for a socket that works but does not serve this channel: `whenNotOffered` is the page's old pace. The one
    /// exception is the same for every screen of the app: with the socket down for three attempts in a row, the visible
    /// page reads once a minute until it is back.
    ///
    /// `readOnOpen: false` is for a page that has just read itself; the socket's own catch-up read still follows.
    static func follow(
        session: OrganizationSession,
        channel: LiveChannel,
        connection: LiveConnection? = nil,
        whenNotOffered: LiveWhenNotOffered,
        readOnOpen: Bool = true,
        legacy: @MainActor () async -> Void,
        refresh: @MainActor () async -> Void
    ) async {
        guard await session.offersLive() else {
            await legacy()
            return
        }
        let live = connection ?? LiveHub.shared.organizationConnection(for: session)
        await LiveRefreshDriver.run(
            connection: live, channels: [channel], whenNotOffered: whenNotOffered,
            initial: { if readOnOpen { await refresh() } },
            onSignals: { _ in await refresh() }
        )
    }
}

extension Duration {
    /// The length in seconds, for the live connection's clock.
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
