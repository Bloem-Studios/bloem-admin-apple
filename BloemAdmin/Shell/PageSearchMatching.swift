import Foundation

/// A page as search reads it: its text as shown, in the interface language.
struct SearchablePage: Identifiable, Equatable {
    let destination: AdminDestination
    let groupLabel: String
    let label: String
    let description: String

    var id: String { destination.id }

    init(destination: AdminDestination, groupLabel: String, label: String, description: String) {
        self.destination = destination
        self.groupLabel = groupLabel
        self.label = label
        self.description = description
    }

    /// The page with its text in the current interface language.
    init(_ destination: AdminDestination) {
        self.init(
            destination: destination,
            groupLabel: String(localized: destination.group.label),
            label: destination.labelText,
            description: destination.descriptionText
        )
    }
}

/// The pages of one group that a search found.
struct PageSearchSection: Identifiable {
    let group: AdminGroup
    let pages: [SearchablePage]

    var id: AdminGroup { group }
}

/// The web's page search, as pure functions: the web's `normalizeSearchText`, `textMatchesTokens` and the
/// command palette's grouping, with the same rules as the Android app.
enum PageSearch {
    /// Lower case, accents dropped, anything but letters, digits and marks a space.
    static func normalize(_ value: String) -> String {
        var result = ""
        var pendingSpace = false
        for scalar in value.lowercased().decomposedStringWithCompatibilityMapping.unicodeScalars {
            if (0x0300...0x036F).contains(scalar.value) { continue }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .nonspacingMark, .spacingMark, .enclosingMark:
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.unicodeScalars.append(scalar)
            default:
                pendingSpace = true
            }
        }
        return result
    }

    static func tokens(_ query: String) -> [String] {
        normalize(query).split(separator: " ").map(String.init)
    }

    /// Every token starts a word or, from four letters, sits inside one.
    private static func matches(_ text: String, tokens: [String]) -> Bool {
        let words = text.split(separator: " ")
        return tokens.allSatisfy { token in
            words.contains { $0.hasPrefix(token) || (token.count >= 4 && $0.contains(token)) }
        }
    }

    /// The pages `query` finds, grouped as the menu groups them. A group whose own name matches keeps all
    /// its pages; otherwise a page matches on its group, label, description and keywords. A blank query
    /// lists every page.
    static func filter(_ pages: [SearchablePage], query: String) -> [PageSearchSection] {
        let queryTokens = Self.tokens(query)
        return AdminGroup.allCases.compactMap { group -> PageSearchSection? in
            let inGroup = pages.filter { $0.destination.group == group }
            guard let first = inGroup.first else { return nil }
            if queryTokens.isEmpty || matches(normalize(first.groupLabel), tokens: queryTokens) {
                return PageSearchSection(group: group, pages: inGroup)
            }
            let found = inGroup.filter { page in
                let text = normalize(
                    ([page.groupLabel, page.label, page.description] + page.destination.keywords).joined(separator: " ")
                )
                return matches(text, tokens: queryTokens)
            }
            return found.isEmpty ? nil : PageSearchSection(group: group, pages: found)
        }
    }
}
