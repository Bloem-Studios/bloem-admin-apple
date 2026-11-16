import Foundation

/// The one place an error becomes text for the person: an API error's own message (or the session
/// handler's, on 401/403), the sign-in text for a missing sign-in, otherwise the caller's fallback.
/// In All Servers mode `serverName` is put in front so the text says which server failed.
@MainActor
enum ErrorMessage {
    static func text(
        for error: Error,
        sessionState: ServerScopedSession?,
        fallback: String,
        serverName: String? = nil
    ) -> String {
        named(plain(for: error, sessionState: sessionState, fallback: fallback), serverName: serverName)
    }

    /// A page's load failure: the kind (can't reach, signed out, no access, server error with its
    /// status, unexpected response) and the text `text(for:...)` would show. The session handler
    /// runs once, here.
    static func failure(
        for error: Error,
        sessionState: ServerScopedSession?,
        fallback: String,
        serverName: String? = nil
    ) -> ServerSectionFailure {
        ServerSectionFailure
            .classify(error, fallback: fallback)
            .replacingMessage(text(for: error, sessionState: sessionState, fallback: fallback, serverName: serverName))
    }

    /// `"<server>: <text>"` when a server is named, otherwise `text` unchanged.
    static func named(_ text: String, serverName: String?) -> String {
        guard let serverName else { return text }
        return String(localized: "\(serverName): \(text)")
    }

    private static func plain(for error: Error, sessionState: ServerScopedSession?, fallback: String) -> String {
        if let apiError = error as? APIError {
            return sessionState?.handleAuthenticationFailure(apiError) ?? apiError.message
        }
        if let notSignedIn = error as? NotSignedInError, let text = notSignedIn.errorDescription {
            return text
        }
        return fallback
    }
}
