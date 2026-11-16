import Foundation
import Observation

/// What a bulk run does to every selected request. The web offers the same two on Needs approval.
enum BulkRequestAction: Sendable, Equatable {
    case approve, decline

    var requestAction: RequestAction {
        switch self {
        case .approve: .approve
        case .decline: .decline
        }
    }
}

/// One request a bulk run acts on, with the server it belongs to. `key` tells two requests with the same
/// number on different servers apart (All servers); `serverID` is nil on a single server's page.
struct BulkRequestItem: Identifiable, Sendable {
    let key: String
    let requestID: String
    let title: String
    let serverID: String?
    /// Named in a failure line where several servers are listed; nil on a single server's page.
    var serverName: String?
    let client: APIClient
    let sessionState: ServerScopedSession?

    var id: String { key }
}

/// A request a bulk run could not answer, with the server's own reason.
struct BulkRequestFailure: Identifiable, Equatable, Sendable {
    let key: String
    let title: String
    let serverName: String?
    let message: String

    var id: String { key }
}

/// How far a bulk run has come. `done` counts every answer, refused ones included.
struct BulkProgress: Equatable, Sendable {
    let action: BulkRequestAction
    let total: Int
    var done: Int
    var failures: [BulkRequestFailure]
    var isRunning: Bool
}

/// Sends the per-request calls a few at a time, as the web's bulk action does
/// (`hooks/queries/admin/requests.ts`, `BULK_REQUEST_CONCURRENCY`). One refusal does not stop the rest.
@MainActor
enum BulkRequestRunner {
    /// Requests in flight at once; the rest wait for a free slot.
    static let concurrency = 4

    struct Failure: Equatable {
        let index: Int
        let message: String
    }

    /// Runs `perform` for every item, at most `limit` at a time. `perform` answers nil when the item went
    /// through, else the reason it did not. `onProgress` gets the number of answers so far after each one.
    /// Returns the failures, in the order they came back.
    static func run<Item: Sendable>(
        _ items: [Item],
        limit: Int = BulkRequestRunner.concurrency,
        perform: @escaping @MainActor (Item) async -> String?,
        onProgress: @MainActor (Int) -> Void
    ) async -> [Failure] {
        var failures: [Failure] = []
        var answered = 0
        await withTaskGroup(of: (Int, String?).self) { group in
            var next = 0
            func launchNext(_ group: inout TaskGroup<(Int, String?)>) {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask { (index, await perform(item)) }
            }
            for _ in 0..<min(max(limit, 1), items.count) { launchNext(&group) }
            while let (index, message) = await group.next() {
                answered += 1
                if let message { failures.append(Failure(index: index, message: message)) }
                onProgress(answered)
                launchNext(&group)
            }
        }
        return failures
    }
}

/// Select mode and the progress of one bulk run on Needs approval. The page keeps one of these; the rows it
/// shows decide which keys exist. A run sends nothing for keys that are no longer shown, because the page
/// hands `run` only the rows that are.
@Observable
@MainActor
final class BulkTriageModel {
    private(set) var isSelecting = false
    private(set) var selectedKeys: Set<String> = []
    /// The run in flight, or the last one's result until select mode ends or a new run starts.
    private(set) var progress: BulkProgress?

    var isRunning: Bool { progress?.isRunning == true }

    func isSelected(_ key: String) -> Bool { selectedKeys.contains(key) }

    func beginSelecting() {
        guard !isRunning else { return }
        isSelecting = true
        progress = nil
    }

    /// Leaves select mode and forgets the selection and the last result. Holds still while a run is going.
    func endSelecting() {
        guard !isRunning else { return }
        isSelecting = false
        selectedKeys = []
        progress = nil
    }

    func toggle(_ key: String) {
        guard isSelecting, !isRunning else { return }
        if selectedKeys.contains(key) { selectedKeys.remove(key) } else { selectedKeys.insert(key) }
    }

    func selectAll(_ keys: [String]) {
        guard isSelecting, !isRunning else { return }
        selectedKeys = Set(keys)
    }

    func deselectAll() {
        guard isSelecting, !isRunning else { return }
        selectedKeys = []
    }

    /// Hides the last result without leaving select mode.
    func dismissResult() {
        guard !isRunning else { return }
        progress = nil
    }

    /// Approves or declines every item, at most four at a time, each on its own server. `note` goes with a
    /// decline only (the server takes none with an approval). Requests that were refused stay selected with
    /// their reason in `progress`; when every one went through, select mode ends. Returns the servers that were
    /// written to, so the page can read just those again.
    @discardableResult
    func run(_ action: BulkRequestAction, on items: [BulkRequestItem], note: String?) async -> Set<String> {
        guard !items.isEmpty, !isRunning else { return [] }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = action == .decline && trimmed?.isEmpty == false ? trimmed : nil
        progress = BulkProgress(action: action, total: items.count, done: 0, failures: [], isRunning: true)
        let failures = await BulkRequestRunner.run(
            items,
            perform: { item in
                do {
                    try await item.client.actOnRequest(id: item.requestID, action: action.requestAction, reason: reason)
                    return nil
                } catch {
                    return RequestQueueViewModel.message(
                        for: error, sessionState: item.sessionState, fallback: String(localized: "The request could not be sent.")
                    )
                }
            },
            onProgress: { [weak self] answered in self?.progress?.done = answered }
        )
        let failed = failures.sorted { $0.index < $1.index }.map { failure in
            let item = items[failure.index]
            return BulkRequestFailure(key: item.key, title: item.title, serverName: item.serverName, message: failure.message)
        }
        progress = BulkProgress(action: action, total: items.count, done: items.count, failures: failed, isRunning: false)
        selectedKeys = Set(failed.map(\.key))
        if failed.isEmpty { isSelecting = false }
        return Set(items.compactMap(\.serverID))
    }
}

extension RequestQueue {
    /// A request that can be approved or declined right now; only these can be selected for a bulk answer.
    static func canAnswerInBulk(_ request: MediaRequest) -> Bool {
        actions(for: request).contains(.approve)
    }
}

/// The words of bulk triage, in the web's wording where it has some (`web.admin.requests.bulk.*`).
enum BulkTriageText {
    static func approveButton(count: Int) -> String { String(localized: "Approve \(count)") }
    static func declineButton(count: Int) -> String { String(localized: "Decline \(count)") }

    static func selected(count: Int) -> String {
        count == 0 ? String(localized: "None selected") : String(localized: "\(count) selected")
    }

    static func selectAll(count: Int) -> String { String(localized: "Select all \(count) shown") }

    static func running(_ action: BulkRequestAction, done: Int, total: Int) -> String {
        switch action {
        case .approve: String(localized: "Approving \(done) of \(total)")
        case .decline: String(localized: "Declining \(done) of \(total)")
        }
    }

    /// What a finished run says. With failures it also says what happens to them.
    static func result(_ action: BulkRequestAction, total: Int, failed: Int) -> String {
        let succeeded = total - failed
        let noun = total == 1 ? String(localized: "request") : String(localized: "requests")
        let verb = action == .approve ? String(localized: "approved") : String(localized: "declined")
        if failed == 0 { return String(localized: "\(total) \(noun) \(verb)") }
        let head = String(localized: "\(succeeded) of \(total) \(noun) \(verb).")
        let tail = failed == 1
            ? String(localized: "The \(failed) that failed stays selected, with its reason.")
            : String(localized: "The \(failed) that failed stay selected, with the reason for each.")
        return head + " " + tail
    }

    static func declineTitle(count: Int) -> String {
        count == 1 ? String(localized: "Decline \(count) request") : String(localized: "Decline \(count) requests")
    }

    static func declineMessage(count: Int) -> String {
        count == 1
            ? String(localized: "The request will be marked declined, and the requester is told. Add an optional note for them.")
            : String(localized: "The requests will be marked declined, and each requester is told. Add an optional note for them.")
    }

    static func failureLine(title: String, message: String) -> String { String(localized: "\(title): \(message)") }
}
