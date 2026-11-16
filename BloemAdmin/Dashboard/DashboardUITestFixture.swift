#if DEBUG
import SwiftUI

/// A dashboard filled from canned, server-shaped JSON, with no network, sign-in or app lock. The
/// UI tests launch it with `--ui-testing-dashboard-fixture` (everything present) or
/// `--ui-testing-dashboard-fixture=sparse` (a stale egress sample, no libraries, no top lists), so
/// they can check the section order, the tile omission and the charts' plain-number fallback
/// without a server.
enum DashboardUITestFixture {
    enum Variant {
        case full, sparse
    }

    static func requested(_ arguments: [String]) -> Variant? {
        if arguments.contains("--ui-testing-dashboard-fixture=sparse") { return .sparse }
        if arguments.contains("--ui-testing-dashboard-fixture") { return .full }
        return nil
    }

    @MainActor
    static func makeModel(_ variant: Variant, now: Date = Date()) -> DashboardViewModel {
        let iso = ISO8601DateFormatter()
        func stamp(_ offset: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(offset)) }
        func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
            // The canned JSON is part of this file; a typo should fail loudly in the test run.
            try! JSONDecoder.iso8601.decode(T.self, from: Data(json.utf8))
        }

        // The newest sample is seconds old, or ten minutes old (stale) in the sparse variant.
        let newestAge: TimeInterval = variant == .full ? 5 : 600
        let lastSample = stamp(-newestAge)
        let points = (0..<30).map { i -> String in
            let kbps = [2000, 4000, 12_000, 40_000, 8000][i % 5]
            return #"{"t":"\#(stamp(-newestAge - Double(29 - i) * 60))","streams":\#(i % 4),"egress_kbps":\#(kbps),"download_egress_kbps":\#(i % 3 == 0 ? 500 : 0)}"#
        }.joined(separator: ",")
        let series = decode(Timeseries.self, """
        {"resolution_seconds":60,"from":"\(stamp(-newestAge - 29 * 60))","to":"\(lastSample)","egress_bytes":1500000000,
         "points":[\(points)]}
        """)
        let activity = decode(PlaybackActivity.self, """
        {"hours":24,"bucket_seconds":3600,"from":"\(stamp(-86_400))","to":"\(stamp(0))",
         "buckets":[{"hour":"\(stamp(-3 * 3600))","direct":3,"remux":1,"transcode":2},{"hour":"\(stamp(-2 * 3600))","direct":5,"remux":0,"transcode":1}],
         "reliability":{"sessions_started":12,"finalized_sessions":8,"completion_rate":0.75},"profiles_active_24h":5}
        """)
        var insights = DashboardInsights()
        insights.status = SectionState(value: decode(DashboardServerStatus.self, """
        {"started_at":"\(stamp(-3 * 86_400))","restart_required":false,
         "health":{"postgres":{"configured":true,"ok":true,"latency_ms":1.5},"redis":{"configured":false},"errors_24h":0,"warnings_24h":2}}
        """))
        insights.build = SectionState(value: decode(BuildInfo.self, #"{"available":true,"build_number":12,"display":"v1.4"}"#))
        insights.nodes = SectionState(value: [DashboardNode(id: "n1", name: "node-1", enabled: true, healthy: true)])
        insights.activity = SectionState(value: activity)
        insights.egressNow = SectionState(value: series)
        insights.egress24h = SectionState(value: series)
        insights.recent = SectionState(value: decode([RecentPlayback].self, """
        [{"session_id":"h1","username":"amy","media_title":"Heat","started_at":"\(stamp(-900))"}]
        """))
        insights.users = SectionState(value: decode([DashboardUser].self, """
        [{"id":"1","username":"alex","role":"admin","enabled":true,"last_active_at":"\(stamp(-300))"}]
        """))
        if variant == .full {
            insights.top = SectionState(value: decode(TopActivity.self, """
            {"days":7,"titles":[{"media_item_id":"m1","title":"Dune","plays":3,"total_seconds":9000}],
             "profiles":[{"user_id":"1","username":"alex","profile_id":"p1","profile_name":"Kids","plays":2,"total_seconds":600}]}
            """))
            insights.libraries = SectionState(value: decode([DashboardLibrary].self, """
            [{"id":"l1","name":"Movies","type":"movie","paths":["/a","/b"],"enabled":true}]
            """))
        }

        let stats = decode(AdminStats.self, """
        {"total_files":1500,"total_movies":400,"total_movie_files":420,"total_shows":60,"total_show_files":1080,"total_storage_bytes":987654321012}
        """)
        let resources = decode(SystemResources.self, """
        {"available":true,"stale":false,"sampled_at":"\(stamp(-10))",
         "system":{"cpu_pct":42,"cores":8,"mem_used_mb":1024,"mem_total_mb":4096,"net_rx_bps":8000,"net_tx_bps":16000}}
        """)
        let sessions = [decode(AdminSession.self, """
        {"session_id":"s1","username":"alex","media_title":"The Real Housewives of Miami","media_type":"series",
         "play_method":"direct","position_seconds":169.7,"file_duration":2600,"is_paused":false,"client_name":"Silo iOS",
         "video_decision":"direct play","audio_decision":"direct play"}
        """)]

        let model = DashboardViewModel()
        model.seed(stats: stats, resources: resources, sessions: sessions, insights: insights, now: now)
        return model
    }
}

/// The screen the fixture launches into.
struct DashboardFixtureRoot: View {
    @State private var model: DashboardViewModel

    init(variant: DashboardUITestFixture.Variant) {
        _model = State(initialValue: DashboardUITestFixture.makeModel(variant))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                DashboardSectionsView(model: model, onShowStreams: {}, onShowUsers: {})
                    .padding()
            }
            .bloemPageBackground()
            .navigationTitle("Dashboard")
            // Opaque, so content scrolled under the bar is not seen by the accessibility audit as
            // text without an element (it reads the blurred pixels through a translucent bar).
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
#endif
