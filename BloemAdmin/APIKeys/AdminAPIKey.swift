import Foundation

/// One API key as `GET /api/v2/admin/api-keys` lists it (`AdminAPIKeyListItem`). Only a short, non-secret prefix is
/// ever sent; a key's secret is shown once when it is created, on the web.
struct AdminAPIKey: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let userID: String
    let label: String
    let keyPrefix: String
    /// `standard` or `elevated`.
    let rateTier: String
    /// What the key is limited to; empty means full access as its owner.
    let scopes: [String]
    let createdAt: Date?
    /// The owning account's username, while the account exists.
    let username: String
    let lastUsedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, label, scopes, username
        case userID = "user_id"
        case keyPrefix = "key_prefix"
        case rateTier = "rate_tier"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userID = try container.decodeIfPresent(String.self, forKey: .userID) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        keyPrefix = try container.decodeIfPresent(String.self, forKey: .keyPrefix) ?? ""
        rateTier = try container.decodeIfPresent(String.self, forKey: .rateTier) ?? "standard"
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    /// A name for the key where it has no label.
    var displayLabel: String { label.isEmpty ? String(localized: "Unnamed key") : label }
}

/// The words of the API keys page.
enum APIKeyText {
    static func scopes(_ scopes: [String]) -> String {
        switch scopes.count {
        case 0: String(localized: "Full access")
        case 1: String(localized: "1 scope: \(scopes[0])")
        default: String(localized: "\(scopes.count) scopes: \(scopes.joined(separator: ", "))")
        }
    }

    /// "Last used 2 hours ago", a date after 30 days, or that it never was.
    static func lastUsed(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return String(localized: "Never used") }
        if now.timeIntervalSince(date) > 30 * 24 * 3600 {
            return String(localized: "Last used \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return String(localized: "Last used \(formatter.localizedString(for: date, relativeTo: now))")
    }

    static func owner(_ username: String) -> String {
        username.isEmpty ? String(localized: "Owner: unknown account") : String(localized: "Owner: \(username)")
    }

    /// Only a raised limit is worth a line.
    static func rateTier(_ tier: String) -> String? {
        tier == "elevated" ? String(localized: "Elevated rate limit") : nil
    }

    static func revokeTitle(_ label: String) -> String { String(localized: "Revoke \(label)?") }

    static func revokeMessage(_ label: String) -> String {
        String(localized: "\(label) stops working at once, and anything using it is refused from now on. This can't be undone.")
    }
}
