import Foundation

/// The web admin's request queue views, in tab order (`requestQueueModel.ts`).
enum RequestQueueView: String, CaseIterable, Identifiable, Sendable {
    case needsApproval = "needs_approval"
    case inProgress = "in_progress"
    case failed
    case done

    var id: String { rawValue }

    var label: String {
        switch self {
        case .needsApproval: String(localized: "Needs approval")
        case .inProgress: String(localized: "In progress")
        case .failed: String(localized: "Failed")
        case .done: String(localized: "Done")
        }
    }

    /// What the view says when it holds nothing at all.
    var emptyText: String {
        switch self {
        case .needsApproval: String(localized: "Nothing is waiting for approval")
        case .inProgress: String(localized: "Nothing is on its way to the library")
        case .failed: String(localized: "No request has failed")
        case .done: String(localized: "No request has finished yet")
        }
    }
}

/// What an admin can do with a request. `cancel` on a failed request closes it.
enum RequestQueueAction: String, Identifiable, Sendable {
    case approve, decline, retry, cancel

    var id: String { rawValue }

    var requestAction: RequestAction {
        switch self {
        case .approve: .approve
        case .decline: .decline
        case .retry: .retry
        case .cancel: .cancel
        }
    }

    var label: String {
        switch self {
        case .approve: String(localized: "Approve")
        case .decline: String(localized: "Decline")
        case .retry: String(localized: "Try again")
        case .cancel: String(localized: "Cancel request")
        }
    }

    var icon: BloemIcon {
        switch self {
        case .approve: .check
        case .decline: .x
        case .retry: .rotateCw
        case .cancel: .ban
        }
    }

    /// Decline and cancel ask for an optional note first.
    var asksForReason: Bool { self == .decline || self == .cancel }
}

/// The state a requester sees, as the web's badge shows it.
enum RequestDisplayState: String, Sendable {
    case pending, approved, processing, available, declined, cancelled, failed
    case partiallyAvailable = "partially_available"

    enum Tone: Sendable { case neutral, progress, success, danger }

    var label: String {
        switch self {
        case .pending: String(localized: "Pending")
        case .approved: String(localized: "Approved")
        case .processing: String(localized: "Processing")
        case .partiallyAvailable: String(localized: "Partially available")
        case .available: String(localized: "Available")
        case .declined: String(localized: "Declined")
        case .cancelled: String(localized: "Cancelled")
        case .failed: String(localized: "Failed")
        }
    }

    var tone: Tone {
        switch self {
        case .pending, .cancelled: .neutral
        case .approved, .processing: .progress
        case .available, .partiallyAvailable: .success
        case .declined, .failed: .danger
        }
    }
}

/// The media-type filter of the queue.
enum RequestMediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all, movie, series

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .movie: String(localized: "Movies")
        case .series: String(localized: "Series")
        }
    }

    /// The `media_type` query value; nil for every type.
    var queryValue: String? { self == .all ? nil : rawValue }
}

/// The web admin queue's rules (`requestQueueModel.ts`, `lib/mediaRequests.ts`), so both apps and the
/// web agree on where a request sits and what can be done with it.
enum RequestQueue {
    /// The view a request belongs to, by the server's own rule.
    static func view(for request: MediaRequest) -> RequestQueueView {
        switch request.outcome {
        case "failed": return .failed
        case "declined", "cancelled": return .done
        default: break
        }
        if request.status == "pending" { return .needsApproval }
        if request.status == "completed" { return .done }
        return .inProgress
    }

    /// The view the queue opens on: what needs approval, else what is under way.
    static func defaultView(_ counts: RequestCounts?) -> RequestQueueView {
        (counts?.needsApproval ?? 0) > 0 ? .needsApproval : .inProgress
    }

    /// Active, and either pending or approved with nothing sent for it yet.
    static func canWithdraw(_ request: MediaRequest) -> Bool {
        guard request.outcome == "active" else { return false }
        if request.status == "pending" { return true }
        return request.status == "approved" && request.targets.isEmpty
    }

    /// Approve or decline what needs approval; cancel what is in progress while nothing has been sent
    /// for it; retry or close what failed.
    static func actions(for request: MediaRequest) -> [RequestQueueAction] {
        switch view(for: request) {
        case .needsApproval: canWithdraw(request) ? [.approve, .decline] : []
        case .inProgress: canWithdraw(request) ? [.cancel] : []
        case .failed: [.retry, .cancel]
        case .done: []
        }
    }

    static func displayState(_ request: MediaRequest) -> RequestDisplayState? {
        if let state = request.state, let known = RequestDisplayState(rawValue: state) { return known }
        if let closed = RequestDisplayState(rawValue: request.outcome),
           [.declined, .cancelled, .failed].contains(closed) { return closed }
        switch request.status {
        case "pending": return .pending
        case "approved": return .approved
        case "queued", "downloading": return .processing
        case "completed": return .available
        default: return nil
        }
    }

    /// The error that stopped the request, else its closing reason.
    static func problem(_ request: MediaRequest) -> (text: String, isError: Bool)? {
        if let error = request.lastError { return (error, true) }
        if let reason = request.outcomeReason { return (reason, false) }
        return nil
    }

    static func mediaTypeLabel(_ mediaType: String) -> String {
        mediaType == "series" ? String(localized: "Series") : String(localized: "Movie")
    }

    /// "Season 2" or "Seasons 1–3, 5", like the web's `formatSeasonList`; nil for none.
    static func seasonList(_ seasons: [Int]) -> String? {
        let sorted = Array(Set(seasons)).sorted()
        guard !sorted.isEmpty else { return nil }
        var runs: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            runs.append(j > i ? "\(sorted[i])–\(sorted[j])" : "\(sorted[i])")
            i = j + 1
        }
        let list = runs.joined(separator: ", ")
        return sorted.count == 1 ? String(localized: "Season \(list)") : String(localized: "Seasons \(list)")
    }

    /// Year · type · seasons.
    static func metaLine(_ request: MediaRequest) -> String {
        [request.year.map { String($0) }, mediaTypeLabel(request.mediaType), seasonList(request.seasons)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The requester's name when the account list knows it, else "User 12", else "Unknown account".
    static func requesterLabel(_ request: MediaRequest, names: [String: String]) -> String {
        guard let id = request.requestedByUserID else { return String(localized: "Unknown account") }
        return names[id] ?? String(localized: "User \(id)")
    }

    /// A target's status in words.
    static func targetStatusLabel(_ status: String) -> String {
        switch status {
        case "failed": String(localized: "Failed")
        case "pending": String(localized: "Pending")
        case "approved": String(localized: "Approved")
        case "queued": String(localized: "Queued")
        case "downloading": String(localized: "Downloading")
        case "completed": String(localized: "Completed")
        default: String(localized: "Requested")
        }
    }

    /// The target's download server, falling back to its kind.
    static func targetServerName(_ target: RequestTarget) -> String {
        if let name = target.instanceName, !name.isEmpty { return name }
        if let kind = target.integrationKind, !kind.isEmpty { return kind }
        return String(localized: "Unknown server")
    }

    /// A download's phase in words; an unknown phase reads as downloading.
    static func downloadPhaseLabel(_ phase: String) -> String {
        switch phase {
        case "queued": String(localized: "Waiting to download")
        case "paused": String(localized: "Download paused")
        case "stalled": String(localized: "Download stalled")
        case "importing": String(localized: "Importing")
        case "import_blocked": String(localized: "Import blocked")
        default: String(localized: "Downloading")
        }
    }

    /// A known phase shows its percentage; an unknown one shows none, as the schema asks.
    static func downloadPercent(_ download: RequestDownload) -> Int? {
        let known = ["queued", "downloading", "paused", "stalled", "importing", "import_blocked"]
        guard known.contains(download.phase), let percent = download.percent else { return nil }
        return min(max(percent, 0), 100)
    }

    /// A history entry's type in plain words; an unknown type shows as it is.
    static func eventLabel(_ type: String) -> String {
        switch type {
        case "created": String(localized: "Requested")
        case "approved", "status_approved": String(localized: "Approved")
        case "status_queued": String(localized: "Sent to the server")
        case "status_downloading": String(localized: "Downloading")
        case "status_completed": String(localized: "Downloaded")
        case "available_in_library": String(localized: "In the library")
        case "outcome_declined": String(localized: "Declined")
        case "outcome_cancelled": String(localized: "Cancelled")
        case "outcome_failed": String(localized: "Failed")
        case "retried": String(localized: "Retried")
        case "submit_deferred": String(localized: "Couldn't send yet")
        default: type
        }
    }

    /// "3 hours ago", or the date once it is more than 30 days old (the web's `absoluteAfterDays: 30`).
    static func requestedAgo(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        if now.timeIntervalSince(date) > 30 * 24 * 3600 {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return date.formatted(.relative(presentation: .named))
    }

    /// The TMDB poster at the web's list size.
    static func posterURL(_ path: String?, size: String = "w92") -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    /// The reason prompt's title, message and confirm label for an action on a request.
    static func reasonPrompt(_ action: RequestQueueAction, request: MediaRequest)
        -> (title: String, message: String, confirm: String)? {
        switch action {
        case .decline:
            return (String(localized: "Decline request"),
                    String(localized: "\"\(request.title)\" will be marked declined. Add an optional note for the requester."),
                    String(localized: "Decline"))
        case .cancel where view(for: request) == .failed:
            return (String(localized: "Close request"),
                    String(localized: "\"\(request.title)\" failed. Closing it moves it to Done, and nothing more is sent for it. Add an optional note."),
                    String(localized: "Close request"))
        case .cancel:
            return (String(localized: "Cancel request"),
                    String(localized: "\"\(request.title)\" will be withdrawn before anything is sent for it. Add an optional note."),
                    String(localized: "Cancel request"))
        case .approve, .retry:
            return nil
        }
    }
}
