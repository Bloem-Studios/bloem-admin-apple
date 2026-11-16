import Foundation

/// The app's side of the mirror: copies the store's tokens out, takes the widget's rotated tokens back in.
struct WidgetCredentialMirror: Sendable {
    let store: (any SharedCredentialStoring)?
    let now: @Sendable () -> Date

    static let disabled = WidgetCredentialMirror(store: nil, now: { Date() })
    static let live = WidgetCredentialMirror(store: KeychainSharedCredentialStore(), now: { Date() })

    var isEnabled: Bool { store != nil }

    /// Writes the app's tokens for a server. A build whose signing lacks the keychain group fails here and
    /// the widgets then say the app has to be opened; nothing else in the app changes.
    func publish(_ credentials: ServerCredentials, serverID: String) {
        try? store?.write(
            SharedCredential(
                accessToken: credentials.accessToken, refreshToken: credentials.refreshToken,
                updatedAt: now(), source: .app
            ),
            serverID: serverID
        )
    }

    func remove(serverID: String) {
        store?.delete(serverID: serverID)
    }

    /// The tokens the widget rotated since the app last wrote the mirror, or nil when the app's store is
    /// already current.
    func rotatedByWidget(serverID: String) -> ServerCredentials? {
        guard case .found(let shared)? = store?.read(serverID: serverID), shared.source == .widget else { return nil }
        return ServerCredentials(
            version: ServerCredentials.currentVersion, accessToken: shared.accessToken, refreshToken: shared.refreshToken
        )
    }
}
