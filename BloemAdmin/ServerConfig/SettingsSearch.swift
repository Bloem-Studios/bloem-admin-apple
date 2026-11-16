import Foundation

/// One thing settings search found.
enum SettingsSearchResult: Identifiable {
    /// A whole page, found by its name, its summary or the web's search words.
    case page(SettingsPage)
    /// One setting of a page, found by its label, help, key or search words.
    case setting(SettingsPage, SettingSpec)
    /// A stored setting the catalogue does not name, found by its key.
    case other(key: String)

    var id: String {
        switch self {
        case .page(let page): "page:\(page.id)"
        case .setting(let page, let spec): "setting:\(page.id):\(spec.key)"
        case .other(let key): "other:\(key)"
        }
    }
}

/// Settings search: the web's page search rules (`PageSearch`) applied to single settings. A query
/// finds pages and individual settings, so "log level" or "smtp" lands on the control and not only on
/// the page that holds it.
enum SettingsSearch {
    /// The settings and pages `query` finds, pages first and in catalogue order; nothing for a blank
    /// query. `otherKeys` are the stored keys the catalogue does not name.
    static func results(
        for query: String, pages: [SettingsPage] = SettingsCatalogue.pages, otherKeys: [String] = []
    ) -> [SettingsSearchResult] {
        let tokens = PageSearch.tokens(query)
        guard !tokens.isEmpty else { return [] }
        var found: [SettingsSearchResult] = []
        for page in pages where matches(pageText(page), tokens: tokens) {
            found.append(.page(page))
        }
        for page in pages {
            for spec in page.settings where matches(settingText(spec), tokens: tokens) {
                found.append(.setting(page, spec))
            }
        }
        for key in otherKeys where matches(PageSearch.normalize(key), tokens: tokens) {
            found.append(.other(key: key))
        }
        return found
    }

    private static func pageText(_ page: SettingsPage) -> String {
        PageSearch.normalize(([page.titleText, page.summaryText] + page.keywords).joined(separator: " "))
    }

    private static func settingText(_ spec: SettingSpec) -> String {
        let parts = [spec.labelText, spec.helpText ?? "", spec.key] + spec.keywords
        return PageSearch.normalize(parts.joined(separator: " "))
    }

    /// Every token starts a word or, from four letters, sits inside one (the web's `textMatchesTokens`).
    private static func matches(_ text: String, tokens: [String]) -> Bool {
        let words = text.split(separator: " ")
        return tokens.allSatisfy { token in
            words.contains { $0.hasPrefix(token) || (token.count >= 4 && $0.contains(token)) }
        }
    }
}
