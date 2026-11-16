import Foundation
import Observation
import SwiftUI

/// When asking a server about requests again is pointless. The web stops polling on these two problems
/// (`hooks/queries/admin/requests.ts`, `useAdminRequestCounts`); any other failure, such as a node that
/// is restarting, is worth asking again.
enum RequestAvailability {
    /// The server runs no request service: its problem type is `dependency_unavailable`.
    static func isUnavailable(_ error: Error) -> Bool {
        (error as? APIError)?.code == "dependency_unavailable"
    }

    /// The signed-in account lost its right to administer requests: `permission_denied`.
    static func isDenied(_ error: Error) -> Bool {
        (error as? APIError)?.code == "permission_denied"
    }

    static func stopsPolling(_ error: Error) -> Bool { isUnavailable(error) || isDenied(error) }
}

/// One server whose Needs approval count feeds the Requests menu badge.
struct RequestBadgeSource: Sendable {
    let serverID: String
    let client: APIClient
}

/// The Needs approval count shown on the Requests menu item (the web's sidebar badge): read from
/// `GET /api/v2/admin/requests/counts`, when the shell opens, when the app returns to the foreground, when a
/// server is added, on pull to refresh and after the person answers a request. There is no timer: the server
/// has no channel for requests (`notifications` is the requester's own inbox), so nothing says when a new one
/// arrives while the app sits open. It is summed over the servers in view. A server that cannot answer keeps its last count; one with no request service, or
/// one that denies the account, counts nothing and is not asked again until `includingStopped`.
@Observable
@MainActor
final class RequestBadgeModel {
    private var counts: [String: Int] = [:]
    private var stopped: Set<String> = []

    var needsApproval: Int { counts.values.reduce(0, +) }

    private enum Answer: Sendable {
        case count(Int)
        case stop
        case failed
    }

    func refresh(sources: [RequestBadgeSource], includingStopped: Bool = false) async {
        let known = Set(sources.map(\.serverID))
        counts = counts.filter { known.contains($0.key) }
        stopped = includingStopped ? [] : stopped.intersection(known)
        let asked = sources.filter { !stopped.contains($0.serverID) }
        let answers = await withTaskGroup(of: (String, Answer).self) { group in
            for source in asked {
                group.addTask {
                    do {
                        return (source.serverID, .count(try await source.client.requestCounts().needsApproval))
                    } catch {
                        return (source.serverID, RequestAvailability.stopsPolling(error) ? .stop : .failed)
                    }
                }
            }
            var all: [(String, Answer)] = []
            for await answer in group { all.append(answer) }
            return all
        }
        // A newer source list may have arrived while the answers were on their way.
        for (serverID, answer) in answers where known.contains(serverID) {
            switch answer {
            case .count(let count): counts[serverID] = count
            case .stop:
                counts[serverID] = nil
                stopped.insert(serverID)
            case .failed: break
            }
        }
    }

    /// The Requests page read this server's counts itself, so the badge follows without another read.
    func record(needsApproval: Int, serverID: String) {
        guard !stopped.contains(serverID) else { return }
        counts[serverID] = needsApproval
    }
}

/// How the menu badge reads: a short count, and the same said in words for VoiceOver.
enum RequestBadgeText {
    static func visible(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    static func spoken(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? String(localized: "\(count) request needs approval") : String(localized: "\(count) requests need approval")
    }
}

// MARK: - Menu wiring

/// What a page can tell the Requests badge: the page read this server's counts, or answered requests and
/// wants the badge to read again. Nil where there is no menu badge (previews, one-screen tests).
struct RequestBadgeActions {
    let record: (_ needsApproval: Int, _ serverID: String) -> Void
    let refresh: () -> Void
}

private struct RequestBadgeActionsKey: EnvironmentKey {
    static var defaultValue: RequestBadgeActions? { nil }
}

extension EnvironmentValues {
    var requestBadge: RequestBadgeActions? {
        get { self[RequestBadgeActionsKey.self] }
        set { self[RequestBadgeActionsKey.self] = newValue }
    }
}

/// Reads `model` once each time the shell appears, the app returns to the foreground or the servers change,
/// and gives the pages inside it a way to report counts they read (`\.requestBadge`). Nothing repeats.
private struct RequestBadgeRefresh: ViewModifier {
    let model: RequestBadgeModel
    let sources: [RequestBadgeSource]
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.requestBadge, RequestBadgeActions(
                record: { count, serverID in model.record(needsApproval: count, serverID: serverID) },
                refresh: { Task { await model.refresh(sources: sources) } }
            ))
            // Keyed on the phase and the servers, so a change of either reads again.
            .task(id: ReadKey(active: scenePhase == .active, servers: sources.map(\.serverID))) {
                guard scenePhase == .active else { return }
                await model.refresh(sources: sources)
            }
    }

    private struct ReadKey: Hashable {
        let active: Bool
        let servers: [String]
    }
}

extension View {
    func requestBadgeRefresh(model: RequestBadgeModel, sources: [RequestBadgeSource]) -> some View {
        modifier(RequestBadgeRefresh(model: model, sources: sources))
    }
}
