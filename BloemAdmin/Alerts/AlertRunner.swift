import Foundation
import WidgetKit

protocol WidgetTimelineReloading: Sendable {
    func reloadAll()
}

struct SystemWidgetReloader: WidgetTimelineReloading {
    func reloadAll() {
        WidgetReload.all()
    }
}

struct AlertRunSummary: Equatable, Sendable {
    /// The servers that were asked, in saved order.
    var checkedServerIDs: [String]
}

/// One check of every saved server: used by the background refresh task and when the app comes to the
/// foreground. It asks the public health route only and never reads a stored sign-in; it tells the person
/// only about servers whose alerts are on, and only while iOS permission is granted.
struct AlertRunner: Sendable {
    let preferences: AlertPreferences
    /// The saved servers, from their metadata only.
    let loadServers: @Sendable () throws -> [AdminServer]
    let probe: any HealthChecking
    let notifier: any AlertNotifying
    let authorizer: any NotificationAuthorizing
    let snapshots: any SnapshotStoring
    let reloader: any WidgetTimelineReloading
    let planner: BackgroundCheckPlanner
    let now: @Sendable () -> Date
    /// Whether this server's "Server is back" notification (the kind `admin.server_up`) is switched on in
    /// Settings → Notifications. Clearing the "can't reach" notice is never gated.
    var backNoticeAllowed: @Sendable (String) -> Bool = { _ in true }

    @discardableResult
    func run() async -> AlertRunSummary {
        let servers = (try? loadServers()) ?? []
        let savedIDs = Set(servers.map(\.id))
        // Nothing about a removed server is kept or checked.
        preferences.prune(keeping: savedIDs)

        guard preferences.isEnabled else {
            planner.reschedule(preferences: preferences, savedServerIDs: savedIDs)
            return AlertRunSummary(checkedServerIDs: [])
        }

        let checkable = servers.filter { !$0.usesInsecureAddress }
        let results = await check(checkable)
        let checkedAt = now()
        let canNotify = await authorizer.status() == .allowed
        var reachability: [String: SnapshotReachability] = [:]

        for server in checkable {
            guard let result = results[server.id], result != .inconclusive else { continue }
            reachability[server.id] = SnapshotReachability(reachable: result == .up, checkedAt: checkedAt)
            guard canNotify, preferences.isServerEnabled(server.id) else { continue }
            let outcome = AlertDecider.apply(result, to: preferences.state(for: server.id), at: checkedAt)
            preferences.setState(outcome.state, for: server.id)
            await act(outcome.action, on: server, at: checkedAt)
        }

        writeSnapshot(servers: servers, reachability: reachability, at: checkedAt)
        planner.reschedule(preferences: preferences, savedServerIDs: savedIDs)
        return AlertRunSummary(checkedServerIDs: checkable.map(\.id))
    }

    private func check(_ servers: [AdminServer]) async -> [String: HealthProbeResult] {
        let probe = probe
        return await withTaskGroup(of: (String, HealthProbeResult).self) { group in
            for server in servers {
                let id = server.id, url = server.baseURL
                group.addTask { (id, await probe.check(baseURL: url)) }
            }
            var all: [String: HealthProbeResult] = [:]
            for await (id, result) in group { all[id] = result }
            return all
        }
    }

    private func act(_ action: AlertAction, on server: AdminServer, at date: Date) async {
        let details = preferences.showsDetails
        switch action {
        case .none:
            break
        case .serverDown(let since, let reason):
            // A new notice replaces the "answering again" one.
            await notifier.removeDelivered(identifiers: [AlertNotificationContent.identifier(.serverBack, serverID: server.id)])
            await notifier.post(.serverDown(
                serverID: server.id, name: server.displayName, since: since, reason: reason, showsDetails: details
            ))
        case .serverBack:
            await notifier.removeDelivered(identifiers: [AlertNotificationContent.identifier(.serverDown, serverID: server.id)])
            guard backNoticeAllowed(server.id) else { return }
            await notifier.post(.serverBack(
                serverID: server.id, name: server.displayName, at: date, showsDetails: details
            ))
        }
    }

    private func writeSnapshot(
        servers: [AdminServer], reachability: [String: SnapshotReachability], at date: Date
    ) {
        let snapshot = AdminSnapshot.make(
            previous: snapshots.load(), servers: servers.map(\.snapshotInfo), reachability: reachability,
            counts: [:], now: date
        )
        try? snapshots.save(snapshot)
        reloader.reloadAll()
    }
}
