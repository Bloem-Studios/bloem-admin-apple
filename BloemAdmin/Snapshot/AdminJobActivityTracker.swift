import ActivityKit
import Foundation
import Observation

// The Live Activity for a library scan or a backup that was started from this app. Started when the app's
// button succeeds, updated from the reads the Libraries and Backups pages make and from the app's own reads
// (`JobActivityFollow`), which the server's `scans`, `jobs` and `tasks` channels trigger over the shared live
// socket, and ended when the server says the job is over. It only follows jobs the app started: a scan that
// autoscan or the web started gets no activity. While the app is in the foreground the socket updates it;
// in the background nothing runs (no socket, no timer, no polling), so the system marks it stale and it
// goes at its stale date.

/// What the activity should say now.
struct AdminJobDecision: Equatable, Sendable {
    var phase: AdminJobActivityAttributes.Phase
    var progress: Double?
}

/// The rules, as plain functions so they are tested without ActivityKit.
enum AdminJobPlanner {
    /// A scan the app started is "running" until the server's active runs stop showing it. A scan that the
    /// list never showed (it finished before the first read) is judged after this long.
    static let graceForUnseenScan: TimeInterval = 30
    /// A job that never reports is not followed past this.
    static let longestFollow: TimeInterval = 2 * 60 * 60

    static func scan(
        libraryID: String, activeRuns: [ScanRun], recentRuns: [ScanRun], startedAt: Date, sawActive: Bool, now: Date
    ) -> (decision: AdminJobDecision?, sawActive: Bool) {
        let active = activeRuns.contains { $0.libraryID == libraryID && $0.status.isActive }
        if active { return (AdminJobDecision(phase: .running, progress: nil), true) }
        if !sawActive && now.timeIntervalSince(startedAt) < graceForUnseenScan {
            return (AdminJobDecision(phase: .running, progress: nil), false)
        }
        let latest = recentRuns.filter { $0.libraryID == libraryID && !$0.status.isActive }
            .max { $0.latestActivity < $1.latestActivity }
        let failed = latest?.status == .failed
        return (AdminJobDecision(phase: failed ? .failed : .finished, progress: nil), sawActive)
    }

    static func backup(overview: BackupsOverview, startedAt: Date, sawActive: Bool, now: Date) -> (decision: AdminJobDecision, sawActive: Bool) {
        if let active = overview.active, active.operation == "backup" {
            return (AdminJobDecision(phase: .running, progress: min(1, max(0, active.progress / 100))), true)
        }
        if !sawActive && now.timeIntervalSince(startedAt) < graceForUnseenScan {
            return (AdminJobDecision(phase: .running, progress: nil), false)
        }
        let failed = overview.lastRun.map { $0.status != "completed" && $0.status != "succeeded" && $0.status != "success" && $0.finishedAt != nil } ?? false
        return (AdminJobDecision(phase: failed ? .failed : .finished, progress: nil), sawActive)
    }
}

@MainActor
protocol AdminJobActivityPresenting: AnyObject {
    func start(_ attributes: AdminJobActivityAttributes, state: AdminJobActivityAttributes.ContentState) -> String?
    func update(id: String, state: AdminJobActivityAttributes.ContentState)
    func end(id: String, state: AdminJobActivityAttributes.ContentState)
}

@MainActor
final class SystemAdminJobActivityPresenter: AdminJobActivityPresenting {
    private var activities: [String: Activity<AdminJobActivityAttributes>] = [:]

    func start(_ attributes: AdminJobActivityAttributes, state: AdminJobActivityAttributes.ContentState) -> String? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(10 * 60))
        guard let activity = try? Activity.request(attributes: attributes, content: content, pushType: nil) else { return nil }
        activities[activity.id] = activity
        return activity.id
    }

    func update(id: String, state: AdminJobActivityAttributes.ContentState) {
        guard let activity = activities[id] else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(10 * 60))
        nonisolated(unsafe) let target = activity
        Task { await target.update(content) }
    }

    func end(id: String, state: AdminJobActivityAttributes.ContentState) {
        guard let activity = activities.removeValue(forKey: id) else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        nonisolated(unsafe) let target = activity
        Task { await target.end(content, dismissalPolicy: .after(Date().addingTimeInterval(5 * 60))) }
    }
}

@MainActor
@Observable
final class AdminJobActivityTracker {
    static let shared = AdminJobActivityTracker()

    private struct Followed {
        var activityID: String?
        var attributes: AdminJobActivityAttributes
        var libraryName: String?
        var sawActive = false
    }

    @ObservationIgnored private let presenter: any AdminJobActivityPresenting
    @ObservationIgnored private let serverName: (String) -> String
    @ObservationIgnored private let now: () -> Date
    /// Keyed by `kind|serverID|libraryID`.
    private var followed: [String: Followed] = [:]

    init(
        presenter: any AdminJobActivityPresenting = SystemAdminJobActivityPresenter(),
        serverName: @escaping (String) -> String = AdminJobActivityTracker.savedServerName,
        now: @escaping () -> Date = { Date() }
    ) {
        self.presenter = presenter
        self.serverName = serverName
        self.now = now
    }

    var followedCount: Int { followed.count }

    /// The servers with a scan or backup Live Activity being followed.
    var followedServerIDs: Set<String> {
        Set(followed.keys.compactMap { $0.split(separator: "|", omittingEmptySubsequences: false).dropFirst().first.map(String.init) })
    }

    /// Reads what the followed jobs on `serverID` need (the library scan runs, the backup overview) and
    /// applies it. Called when the live socket says something changed, never on a timer.
    func refresh(serverID: String, client: APIClient) async {
        let scanPrefix = "\(AdminJobActivityAttributes.Kind.libraryScan.rawValue)|\(serverID)|"
        if followed.keys.contains(where: { $0.hasPrefix(scanPrefix) }),
           let snapshot = try? await client.librariesSnapshot() {
            librariesRead(serverID: serverID, activeRuns: snapshot.activeRuns, recentRuns: snapshot.recentRuns)
        }
        if followed[key(.backup, serverID, nil)] != nil, let overview = try? await client.backupsOverview() {
            backupRead(serverID: serverID, overview: overview)
        }
    }

    nonisolated static func savedServerName(_ id: String) -> String {
        FileSnapshotStore.appGroup()?.load()?.servers.first { $0.id == id }?.name ?? String(localized: "Silo server")
    }

    private func key(_ kind: AdminJobActivityAttributes.Kind, _ serverID: String, _ libraryID: String?) -> String {
        "\(kind.rawValue)|\(serverID)|\(libraryID ?? "")"
    }

    // MARK: Library scans

    /// The server accepted a scan the person started here.
    func scanStarted(serverID: String?, libraryID: String, libraryName: String) {
        guard let serverID else { return }
        let attributes = AdminJobActivityAttributes(
            kind: .libraryScan, serverID: serverID, serverName: serverName(serverID), startedAt: now()
        )
        let state = AdminJobActivityAttributes.ContentState(phase: .running, progress: nil, libraryName: libraryName)
        let id = presenter.start(attributes, state: state)
        followed[key(.libraryScan, serverID, libraryID)] = Followed(activityID: id, attributes: attributes, libraryName: libraryName)
    }

    /// A read of the Libraries page.
    func librariesRead(serverID: String?, activeRuns: [ScanRun], recentRuns: [ScanRun]) {
        guard let serverID else { return }
        let prefix = "\(AdminJobActivityAttributes.Kind.libraryScan.rawValue)|\(serverID)|"
        for (mapKey, item) in followed where mapKey.hasPrefix(prefix) {
            let libraryID = String(mapKey.dropFirst(prefix.count))
            let verdict = AdminJobPlanner.scan(
                libraryID: libraryID, activeRuns: activeRuns, recentRuns: recentRuns,
                startedAt: item.attributes.startedAt, sawActive: item.sawActive, now: now()
            )
            guard let decision = verdict.decision else { continue }
            apply(decision, key: mapKey, libraryName: item.libraryName, sawActive: verdict.sawActive)
        }
    }

    // MARK: Backups

    func backupStarted(serverID: String?) {
        guard let serverID else { return }
        let attributes = AdminJobActivityAttributes(
            kind: .backup, serverID: serverID, serverName: serverName(serverID), startedAt: now()
        )
        let state = AdminJobActivityAttributes.ContentState(phase: .running, progress: nil, libraryName: nil)
        let id = presenter.start(attributes, state: state)
        followed[key(.backup, serverID, nil)] = Followed(activityID: id, attributes: attributes, libraryName: nil)
    }

    /// A read of the Backups page.
    func backupRead(serverID: String?, overview: BackupsOverview) {
        guard let serverID else { return }
        let mapKey = key(.backup, serverID, nil)
        guard let item = followed[mapKey] else { return }
        let verdict = AdminJobPlanner.backup(overview: overview, startedAt: item.attributes.startedAt, sawActive: item.sawActive, now: now())
        apply(verdict.decision, key: mapKey, libraryName: nil, sawActive: verdict.sawActive)
    }

    private func apply(_ decision: AdminJobDecision, key mapKey: String, libraryName: String?, sawActive: Bool) {
        guard var item = followed[mapKey] else { return }
        item.sawActive = sawActive
        let state = AdminJobActivityAttributes.ContentState(phase: decision.phase, progress: decision.progress, libraryName: libraryName)
        if decision.phase == .running {
            if let id = item.activityID { presenter.update(id: id, state: state) }
            followed[mapKey] = item
        } else {
            if let id = item.activityID { presenter.end(id: id, state: state) }
            followed[mapKey] = nil
        }
    }

    /// Ends what is still followed after `AdminJobPlanner.longestFollow`.
    func endStale() {
        for (mapKey, item) in followed where now().timeIntervalSince(item.attributes.startedAt) > AdminJobPlanner.longestFollow {
            apply(AdminJobDecision(phase: .finished, progress: nil), key: mapKey, libraryName: item.libraryName, sawActive: item.sawActive)
        }
    }
}
