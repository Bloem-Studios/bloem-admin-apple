import Foundation

/// Builds the path part of an API request. Every ID that goes into a path passes through
/// `segment(_:)` so it stays exactly one path segment.
enum APIPath {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Percent-encodes every character outside RFC 3986 unreserved. A segment made only of dots
    /// (`.` or `..`) has its dots encoded too, so no client or server resolves it away.
    static func segment(_ value: String) -> String {
        let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return encoded == "." || encoded == ".." ? encoded.replacingOccurrences(of: ".", with: "%2E") : encoded
    }

    /// True when `path` only contains characters allowed in an encoded path, with well-formed `%XX` escapes.
    static func isValidEncodedPath(_ path: String) -> Bool {
        let allowed = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "%"))
        guard path.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let scalars = Array(path.unicodeScalars)
        for (index, scalar) in scalars.enumerated() where scalar == "%" {
            guard index + 2 < scalars.count,
                  scalars[index + 1].properties.isASCIIHexDigit,
                  scalars[index + 2].properties.isASCIIHexDigit else { return false }
        }
        return true
    }
}
