import Foundation

/// How a log entry is read in its detail sheet, and the text Copy and Share send (the web's
/// log detail sheet, AdminLogs.tsx).
enum LogIdentifier {
    /// "ps_7f3a9…e5f6": the start and end of a long ID, as the web's shortID does.
    static func short(_ value: String) -> String {
        guard value.count > 12 else { return value }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }
}

/// Attribute names that can carry a client address; hidden with the address when the setting hides them.
private func isAddressKey(_ key: String) -> Bool {
    let name = key.lowercased()
    return ["ip", "remote_addr", "remote_ip", "client_addr", "x_forwarded_for", "forwarded_for"].contains(name)
        || name.hasSuffix("_ip") || name.hasSuffix("_ips") || name.hasSuffix("_addr")
}

extension OperationalLogEntry {
    private func attribute(_ key: String) -> String? {
        guard let value = attrs?[key] else { return nil }
        let text = value.editText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || value.isNull ? nil : text
    }

    var method: String? { attribute("method") }
    var statusText: String? { attribute("status") }
    var path: String? { attribute("path") }

    /// "1840 ms" from the `duration_ms` attribute.
    var durationText: String? { attribute("duration_ms").map { "\($0) ms" } }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var effectiveClientIP: String? { nonEmpty(clientIP) ?? attribute("client_ip") }
    var effectiveSessionID: String? { nonEmpty(sessionID) ?? attribute("session_id") }
    var effectivePlaybackSessionID: String? { nonEmpty(playbackSessionID) ?? attribute("playback_session_id") }

    /// The attributes as sorted, indented JSON; nil when there are none.
    func attributesText(showsClientIP: Bool = true) -> String? {
        guard var attrs, !attrs.isEmpty else { return nil }
        if !showsClientIP { attrs = attrs.filter { !isAddressKey($0.key) } }
        guard !attrs.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(attrs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The entry as plain text for Copy and Share. The client address is left out when the page
    /// does not show addresses.
    func detailText(showsClientIP: Bool) -> String {
        var lines = [
            "\(level.uppercased()) · \(component)",
            message,
            String(localized: "Time: \(timestamp.formatted(.iso8601))"),
        ]
        func add(_ label: String, _ value: String?) {
            if let value = nonEmpty(value) { lines.append("\(label): \(value)") }
        }
        add(String(localized: "Request ID"), requestID)
        add(String(localized: "Node"), nodeID)
        add(String(localized: "Method"), method)
        add(String(localized: "Status"), statusText)
        add(String(localized: "Duration"), durationText)
        add(String(localized: "Path"), path)
        if showsClientIP { add(String(localized: "Client IP"), effectiveClientIP) }
        add(String(localized: "User"), userID)
        add(String(localized: "Session"), effectiveSessionID)
        add(String(localized: "Playback session"), effectivePlaybackSessionID)
        if let attributes = attributesText(showsClientIP: showsClientIP) {
            lines.append(String(localized: "Attributes:"))
            lines.append(attributes)
        }
        return lines.joined(separator: "\n")
    }
}
