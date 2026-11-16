import Foundation

enum ServerEndpointValidationError: Error, LocalizedError, Equatable {
    case empty
    case invalidURL
    case requiresHTTPS
    case missingHost
    case invalidPort
    case userInfoNotAllowed
    case queryNotAllowed
    case fragmentNotAllowed
    case pathNotAllowed

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter the server's HTTPS address."
        case .invalidURL:
            return "That doesn't look like a valid URL."
        case .requiresHTTPS:
            return "The server address must use HTTPS."
        case .missingHost:
            return "The server address must include a host."
        case .invalidPort:
            return "The server address must use a port between 1 and 65535."
        case .userInfoNotAllowed:
            return "The server address cannot include a username or password."
        case .queryNotAllowed, .fragmentNotAllowed, .pathNotAllowed:
            return "Enter only the server origin, without a path, query, or fragment."
        }
    }
}

enum ServerEndpointValidator {
    /// An address an administrator typed: without a scheme it is taken as HTTPS, so
    /// `media.example.com` works. A scheme that is typed is kept and checked, so `http://` is still
    /// refused, as are paths, queries and sign-in details.
    static func validateTyped(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServerEndpointValidationError.empty }
        return try validate(trimmed.contains("://") ? trimmed : "https://" + trimmed)
    }

    /// Whether a typed address looks finished enough to check without a tap: a valid HTTPS origin
    /// whose host ends in a top-level label of two or more characters with a letter
    /// (`media.example.com`). `localhost` and IP addresses are still checked, but only on Continue.
    static func isFinishedAddress(_ input: String) -> Bool {
        guard let host = (try? validateTyped(input))?.host else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let top = labels.last else { return false }
        return top.count >= 2 && top.contains(where: \.isLetter)
    }

    static func validate(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServerEndpointValidationError.empty }
        guard let components = URLComponents(string: trimmed) else {
            throw ServerEndpointValidationError.invalidURL
        }
        guard components.scheme?.lowercased() == "https" else {
            throw ServerEndpointValidationError.requiresHTTPS
        }
        guard let host = components.host, !host.isEmpty else {
            throw ServerEndpointValidationError.missingHost
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw ServerEndpointValidationError.invalidPort
        }
        guard components.user == nil, components.password == nil else {
            throw ServerEndpointValidationError.userInfoNotAllowed
        }
        guard components.query == nil else {
            throw ServerEndpointValidationError.queryNotAllowed
        }
        guard components.fragment == nil else {
            throw ServerEndpointValidationError.fragmentNotAllowed
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw ServerEndpointValidationError.pathNotAllowed
        }

        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = host.lowercased()
        canonical.port = components.port == 443 ? nil : components.port
        guard let url = canonical.url else {
            throw ServerEndpointValidationError.invalidURL
        }
        return url
    }
}
