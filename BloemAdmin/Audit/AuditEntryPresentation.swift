import Foundation

/// How an audit entry reads: the action with its before and after lines is the headline, METHOD and
/// path come second (the web's AuditLogRow and its auditChange* helpers in AdminLogs.tsx).
extension AuditLogEntry {
    /// The action, or "HTTP request" for a request the server records without one.
    var headline: String {
        let name = action?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? String(localized: "HTTP request") : name
    }

    var requestLine: String { "\(method) \(path)" }

    /// "user #42", "access group #3", "API key #3"; nil without a target type.
    var targetLabel: String? {
        guard let targetType, !targetType.isEmpty else { return nil }
        let type = targetType == "api_key" ? String(localized: "API key") : targetType.replacingOccurrences(of: "_", with: " ")
        guard let targetID, !targetID.isEmpty else { return type }
        return "\(type) #\(targetID)"
    }

    /// "as 7 → 42" while another administrator acted for the person, "User 42", or nil.
    var actorText: String? {
        if let impersonatorUserID { return String(localized: "as \(impersonatorUserID) → \(userID ?? "?")") }
        if let userID { return String(localized: "User \(userID)") }
        return nil
    }

    /// The entry as plain text for Copy and Share. The client address and user agent are left out
    /// when the page does not show addresses.
    func detailText(showsClientIP: Bool) -> String {
        var lines = [headline]
        lines.append(contentsOf: changes.map { $0.line(targetType: targetType) })
        lines.append(requestLine)
        lines.append(String(localized: "Time: \(timestamp.formatted(.iso8601))"))
        lines.append(String(localized: "Status: \(statusCode)"))
        lines.append(String(localized: "Duration: \(durationMs) ms"))
        func add(_ label: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { lines.append("\(label): \(trimmed)") }
        }
        add(String(localized: "Target"), targetLabel)
        add(String(localized: "User"), actorText)
        if showsClientIP {
            add(String(localized: "Client IP"), clientIP)
            add(String(localized: "User agent"), userAgent)
        }
        add(String(localized: "Request ID"), requestID)
        add(String(localized: "Node"), nodeID)
        add(String(localized: "Session"), sessionID)
        add(String(localized: "Playback session"), playbackSessionID)
        return lines.joined(separator: "\n")
    }
}

extension AuditChange {
    /// "role: user → admin". Field names read without underscores, as the web prints them.
    func line(targetType: String?) -> String {
        "\(field.replacingOccurrences(of: "_", with: " ")): \(summary(targetType: targetType))"
    }

    private func summary(targetType: String?) -> String {
        if before == nil && after == nil { return String(localized: "changed") }
        if targetType == "profile" && field == "pin" { return pinSummary }
        let before = Self.value(before, targetType: targetType, field: field)
        let after = Self.value(after, targetType: targetType, field: field)
        return "\(before) → \(after)"
    }

    /// A profile PIN is audited as a set-or-not marker; true to true is a PIN replaced by another.
    private var pinSummary: String {
        if let before, let after {
            if before == after { return String(localized: "changed") }
            return "\(Self.pinLabel(before)) → \(Self.pinLabel(after))"
        }
        return after == "true" ? String(localized: "set") : String(localized: "cleared")
    }

    private static func pinLabel(_ value: String) -> String {
        value == "true" ? String(localized: "set") : String(localized: "not set")
    }

    private static func value(_ raw: String?, targetType: String?, field: String) -> String {
        guard let raw else { return String(localized: "absent") }
        guard let data = raw.data(using: .utf8), let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else { return raw }
        switch parsed {
        case .null:
            if field == "access_group_id" { return String(localized: "none") }
            if targetType == "access_group" {
                if field == "library_ids" { return String(localized: "all libraries") }
                if field == "allowed_permissions" { return String(localized: "all assignable") }
                return String(localized: "unset")
            }
            return String(localized: "inherit")
        case .array(let items):
            if items.isEmpty { return field == "scopes" ? String(localized: "full access") : String(localized: "none") }
            return items.map(\.editText).joined(separator: ", ")
        case .object: return parsed.editText
        default: return parsed.editText
        }
    }
}
