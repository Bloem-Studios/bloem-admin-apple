import Foundation

/// What the control says. The widgets keep the stored count current; the open app's snapshot is the fallback.
enum RequestsWaitingCount {
    static func current(
        cache: WidgetDataCache? = FileWidgetDataStore.appGroup()?.load(),
        snapshot: AdminSnapshot? = FileSnapshotStore.appGroup()?.load(),
        now: Date = Date()
    ) -> Int {
        let totals = (cache?.requests ?? [:]).values.filter { $0.hasData }.compactMap(\.total)
        if !totals.isEmpty { return totals.reduce(0, +) }
        return SnapshotSummary(servers: snapshot?.servers ?? [], now: now).requestsWaiting ?? 0
    }

    static func text(_ count: Int) -> String {
        count == 0 ? String(localized: "No requests waiting") : String(localized: "\(count) requests waiting")
    }
}
