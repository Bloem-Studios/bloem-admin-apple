import Foundation

struct AdminServer: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var baseURL: URL
    var displayName: String
    /// The ID of the provider this server was last signed in with, listed first at re-login. It is not a
    /// secret. Password sign-in clears it. Records saved before OAuth sign-in decode it as nil.
    var signInProviderID: String?
}

extension AdminServer {
    /// Servers must be reached over HTTPS. One saved with another scheme (an older record) cannot be opened;
    /// Manage servers says so and offers Remove.
    var usesInsecureAddress: Bool { baseURL.scheme?.lowercased() != "https" }
}
