import Foundation

/// The filters of the Playback history page: one person (picked by name, sent as their ID), one of
/// that person's profiles, and completed or partial plays. A profile belongs to one person, so it
/// only counts together with a person.
struct HistoryFilter: Equatable, Sendable {
    enum Completion: String, CaseIterable, Identifiable, Sendable {
        case all, completed, partial

        var id: String { rawValue }

        /// The route's `completed` value; nil for all plays, which the route's default already is.
        var queryValue: String? {
            switch self {
            case .all: nil
            case .completed: "true"
            case .partial: "false"
            }
        }

        var title: String {
            switch self {
            case .all: String(localized: "All plays")
            case .completed: String(localized: "Completed")
            case .partial: String(localized: "Partial")
            }
        }
    }

    var userID: String
    var profileID: String
    var completion: Completion

    init(userID: String = "", profileID: String = "", completion: Completion = .all) {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userID = user
        self.profileID = user.isEmpty ? "" : profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.completion = completion
    }

    /// The same filter with the trimming and profile rule applied again after a field was edited.
    var normalized: HistoryFilter {
        HistoryFilter(userID: userID, profileID: profileID, completion: completion)
    }

    var isEmpty: Bool { normalized == HistoryFilter() }

    /// The query items for the route; unset filters are left out.
    var query: [String: String] {
        let filter = normalized
        var items: [String: String] = [:]
        if !filter.userID.isEmpty { items["user_id"] = filter.userID }
        if !filter.profileID.isEmpty { items["profile_id"] = filter.profileID }
        if let completed = filter.completion.queryValue { items["completed"] = completed }
        return items
    }
}
