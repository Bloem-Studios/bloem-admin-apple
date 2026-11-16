import Foundation

/// One option of a setting that offers a fixed choice. `value` is what the server stores.
struct SettingChoice: Sendable {
    let value: String
    let label: LocalizedStringResource

    init(_ value: String, _ label: LocalizedStringResource) {
        self.value = value
        self.label = label
    }
}

/// How a setting is shown and edited. Every setting travels as text; the control decides how that
/// text reads on screen.
enum SettingControl: Sendable {
    case toggle
    /// A whole number. `scale` divides the stored number for display (bytes shown as gigabytes).
    case number(unit: LocalizedStringResource? = nil, min: Int? = nil, max: Int? = nil, scale: Int64 = 1)
    case choice([SettingChoice])
    case text(placeholder: String? = nil, kind: SettingTextKind = .plain)
    /// Write-only: the page shows whether a value is set, never the value.
    case secret
}

enum SettingTextKind: Sendable {
    case plain, url, email
}

/// One setting of the catalogue: the server key, a label and help in the web's words, and the control.
struct SettingSpec: Identifiable, Sendable {
    let key: String
    let label: LocalizedStringResource
    let help: LocalizedStringResource?
    let control: SettingControl
    /// English search terms beyond the label and help; never shown.
    let keywords: [String]

    var id: String { key }

    init(
        _ key: String, _ label: LocalizedStringResource, control: SettingControl,
        help: LocalizedStringResource? = nil, keywords: [String] = []
    ) {
        self.key = key
        self.label = label
        self.control = control
        self.help = help
        self.keywords = keywords
    }

    var labelText: String { String(localized: label) }
    var helpText: String? { help.map { String(localized: $0) } }

    var isSecret: Bool {
        if case .secret = control { return true }
        return false
    }
}

/// A titled group of settings on a page, with an optional line under it.
struct SettingsSection: Identifiable, Sendable {
    let title: LocalizedStringResource?
    let footer: LocalizedStringResource?
    let settings: [SettingSpec]

    var id: String { title.map { String(localized: $0) } ?? settings.first?.key ?? "section" }

    init(_ title: LocalizedStringResource? = nil, footer: LocalizedStringResource? = nil, _ settings: [SettingSpec]) {
        self.title = title
        self.footer = footer
        self.settings = settings
    }
}

/// Something a page offers besides its settings: a test, a status list.
enum SettingsPageExtra: Sendable, Equatable {
    /// A connection check against the page's unsaved values (`POST /settings/check/{kind}`).
    case connectionCheck(kind: String, keys: [String])
    /// Send a test email through the saved mail settings.
    case emailTest
    /// The server notification channels, each with a test.
    case serverChannels
    /// The single sign-on plugins, each with a connection test.
    case signInProviders
}

/// How a page gets its content.
enum SettingsPageKind: Sendable, Equatable {
    /// Settings read and written through `/api/v2/admin/settings`.
    case keys
    /// The request settings, which have their own route (`/api/v2/admin/request-settings`).
    case requests
    /// Overlay network providers: status and Connect, with no settings keys.
    case networkAccess
}

/// A named settings page, as the web's settings sidebar names it.
struct SettingsPage: Identifiable, Sendable {
    /// The web's page id (`general`, `sign-in`), also its route segment.
    let id: String
    let title: LocalizedStringResource
    /// The web's one-line description of the page.
    let summary: LocalizedStringResource
    let icon: BloemIcon
    /// The web's English search synonyms for the page; never shown.
    let keywords: [String]
    let kind: SettingsPageKind
    let sections: [SettingsSection]
    let extras: [SettingsPageExtra]

    init(
        id: String, title: LocalizedStringResource, summary: LocalizedStringResource, icon: BloemIcon,
        keywords: [String], kind: SettingsPageKind = .keys, sections: [SettingsSection] = [],
        extras: [SettingsPageExtra] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.icon = icon
        self.keywords = keywords
        self.kind = kind
        self.sections = sections
        self.extras = extras
    }

    var titleText: String { String(localized: title) }
    var summaryText: String { String(localized: summary) }
    var settings: [SettingSpec] { sections.flatMap(\.settings) }
    var keys: [String] { settings.map(\.key) }
}

/// The app's key catalogue: the pages and, on them, every setting the app names. It mirrors the web's
/// `lib/adminSettingsSearch.ts`; a key the catalogue does not list stays reachable under Other settings.
enum SettingsCatalogue {
    static let pages: [SettingsPage] = [
        general, networkAccess, signIn, playback, logging, email, notifications, downloads, requests,
    ]

    static func page(id: String) -> SettingsPage? { pages.first { $0.id == id } }

    /// Where a key lives: its page and spec.
    static func spec(forKey key: String) -> (page: SettingsPage, spec: SettingSpec)? {
        for page in pages {
            if let spec = page.settings.first(where: { $0.key == key }) { return (page, spec) }
        }
        return nil
    }

    /// Every key the catalogue names, for telling which stored keys belong under Other settings.
    static let knownKeys: Set<String> = Set(pages.flatMap(\.keys))

    /// The label an administrator knows a setting by; the key itself, made readable, when the
    /// catalogue does not name it.
    static func label(forKey key: String) -> String {
        spec(forKey: key)?.spec.labelText ?? ServerStatus.humanize(key)
    }
}

// MARK: - Values

extension SettingControl {
    /// What a field shows for a stored `raw` value.
    func displayValue(_ raw: String) -> String {
        guard case .number(_, _, _, let scale) = self, scale > 1, let number = Int64(raw.trimmingCharacters(in: .whitespaces)) else {
            return raw
        }
        if number % scale == 0 { return String(number / scale) }
        return String(format: "%g", Double(number) / Double(scale))
    }

    /// The stored text for what the person typed; nil when it is not a number this control accepts.
    func storedValue(fromDisplay text: String) -> String? {
        guard case .number(_, _, _, let scale) = self else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        if scale > 1 {
            guard let value = Double(trimmed), value >= 0 else { return nil }
            return String(Int64((value * Double(scale)).rounded()))
        }
        guard Int64(trimmed) != nil else { return nil }
        return String(Int64(trimmed)!)
    }

    /// What is wrong with `raw` for this control, in words for the person; nil when it is fine. The
    /// server still has the last word.
    func problem(with raw: String) -> String? {
        guard case .number(_, let min, let max, _) = self else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        guard let number = Int64(trimmed) else { return String(localized: "Use a whole number") }
        if let min, number < Int64(min) {
            return String(localized: "Use \(min) or more")
        }
        if let max, number > Int64(max) {
            return String(localized: "Use \(max) or less")
        }
        return nil
    }
}
