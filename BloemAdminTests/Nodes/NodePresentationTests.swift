import XCTest
@testable import BloemAdmin

/// What the Nodes page says about a node, from `GET /api/v2/admin/nodes/summary`: its state in words
/// (disabled beats unhealthy beats draining), the load readings, capacity and the last health check.
final class NodePresentationTests: XCTestCase {
    private let now = AdminTimestamp.date(from: "2026-11-15T12:00:00Z")!
    private let en = Locale(identifier: "en_US")

    private func node(
        type: String = "transcode", enabled: Bool = true, healthy: Bool = true,
        drain: String = "none", drainRequested: Bool = false, active: Int = 2, maxJobs: String = "4",
        egress: Int = 12_500, maxBandwidth: String = "null", checked: String = #""2026-11-15T11:57:00Z""#,
        resources: String? = nil, group: String = #""rack-1""#
    ) throws -> NodeSummary {
        var json = #"""
        {"id":"n1","name":"node-1","type":"\#(type)","enabled":\#(enabled),"healthy":\#(healthy),"group":\#(group),
         "drain_state":"\#(drain)","drain_requested":\#(drainRequested),"active_jobs":\#(active),"max_jobs":\#(maxJobs),
         "egress_kbps":\#(egress),"max_bandwidth_kbps":\#(maxBandwidth),"last_health_check":\#(checked),"created_at":"2026-01-01T00:00:00Z"
        """#
        if let resources { json += #","resources":\#(resources)"# }
        return try JSONDecoder().decode(NodeSummary.self, from: Data((json + "}").utf8))
    }

    private let sample = #"""
    {"gpu":[],"sampled_at":"2026-11-15T11:59:58Z","system":{"cpu_pct":37,"load1":1.5,"cores":8,"mem_used_mb":3072,"mem_total_mb":8192,
     "disks":[{"used_gb":50,"total_gb":100,"path":"/"},{"used_gb":90,"total_gb":100,"path":"/media"}],"net_rx_bps":2500000,"net_tx_bps":400000}}
    """#

    // MARK: State

    func testStateIsHealthyForAnEnabledHealthyNode() throws {
        XCTAssertEqual(NodePresentation(node: try node(), now: now, locale: en).stateText, "Healthy")
    }

    func testDisabledBeatsUnhealthy() throws {
        let row = NodePresentation(node: try node(enabled: false, healthy: false), now: now, locale: en)
        XCTAssertEqual(row.stateText, "Disabled")
        XCTAssertEqual(row.state, .disabled)
    }

    // The quality audit (2026-11-16): "Unhealthy" was drawn like "Healthy". A node that needs a look carries a tone and a dot.
    func testTheStateWordIsSaidInTheToneOfHowSeriousItIs() throws {
        XCTAssertEqual(NodeState.unhealthy.statusTone, .failure)
        XCTAssertEqual(NodeState.draining.statusTone, .warning)
        XCTAssertEqual(NodeState.drained.statusTone, .warning)
        XCTAssertEqual(NodeState.healthy.statusTone, .positive)
        XCTAssertEqual(NodeState.disabled.statusTone, .normal)
        let unhealthy = NodePresentation(node: try node(healthy: false), now: now, locale: en)
        XCTAssertEqual(unhealthy.state.statusTone, .failure)
    }

    func testUnhealthyBeatsDraining() throws {
        let row = NodePresentation(node: try node(healthy: false, drain: "draining", drainRequested: true), now: now, locale: en)
        XCTAssertEqual(row.stateText, "Unhealthy")
    }

    func testDrainingAndDrainedAreNamedWithWhatToExpect() throws {
        let draining = NodePresentation(node: try node(drain: "draining", drainRequested: true, active: 3), now: now, locale: en)
        XCTAssertEqual(draining.stateText, "Draining")
        XCTAssertEqual(draining.drainLabel, "Draining, 3 jobs still running")
        XCTAssertEqual(draining.drainDetail, "New work goes to other nodes. Sessions already here keep playing until they end")

        let drained = NodePresentation(node: try node(drain: "drained", drainRequested: true, active: 0), now: now, locale: en)
        XCTAssertEqual(drained.stateText, "Drained")
        XCTAssertEqual(drained.drainLabel, "Drained, safe to stop")
    }

    func testNoDrainTextWhenNotDraining() throws {
        XCTAssertNil(NodePresentation(node: try node(), now: now, locale: en).drainLabel)
    }

    // MARK: Actions offered

    func testDrainIsOfferedOnAnEnabledTranscodeNodeAndResumeOnceRequested() throws {
        let idle = NodePresentation(node: try node(), now: now, locale: en)
        XCTAssertTrue(idle.canDrain)
        XCTAssertFalse(idle.canResume)

        let draining = NodePresentation(node: try node(drain: "draining", drainRequested: true), now: now, locale: en)
        XCTAssertFalse(draining.canDrain)
        XCTAssertTrue(draining.canResume)
    }

    func testProxyNodesDoNotDrain() throws {
        let row = NodePresentation(node: try node(type: "proxy"), now: now, locale: en)
        XCTAssertFalse(row.canDrain)
        XCTAssertFalse(row.canResume)
    }

    func testADisabledNodeCannotBeDrainedButCanBeEnabled() throws {
        let row = NodePresentation(node: try node(enabled: false), now: now, locale: en)
        XCTAssertFalse(row.canDrain)
        XCTAssertEqual(row.enableActionTitle, "Enable")
        XCTAssertEqual(NodePresentation(node: try node(), now: now, locale: en).enableActionTitle, "Disable")
    }

    // MARK: Load

    func testLoadReadingsFromTheLatestSample() throws {
        let row = NodePresentation(node: try node(resources: sample), now: now, locale: en)
        XCTAssertEqual(row.load?.cpu, "37%")
        XCTAssertEqual(row.load?.memory, "3.0 of 8.0 GB")
        XCTAssertEqual(row.load?.disk, "90% used")
        XCTAssertEqual(row.load?.diskWarning, true, "85% and over is called out")
        XCTAssertEqual(row.load?.network, "In 2.5 Mbps, out 0.4 Mbps")
        XCTAssertNil(row.loadUnavailable)
    }

    func testNoSampleSaysSo() throws {
        let row = NodePresentation(node: try node(), now: now, locale: en)
        XCTAssertNil(row.load)
        XCTAssertEqual(row.loadUnavailable, "No resource sample yet")
    }

    func testAnOldSampleIsCalledOutNotShown() throws {
        let old = sample.replacingOccurrences(of: "2026-11-15T11:59:58Z", with: "2026-11-15T11:40:00Z")
            .replacingOccurrences(of: #""system":"#, with: #""attribution":{"sample_interval_seconds":5,"sample_duration_seconds":1,"dropped_disk_roots":0,"instance_id":"i"},"system":"#)
        let row = NodePresentation(node: try node(resources: old), now: now, locale: en)
        XCTAssertNil(row.load)
        XCTAssertEqual(row.loadUnavailable, "The last resource sample is out of date")
    }

    // MARK: Capacity

    func testCapacityWithAndWithoutACap() throws {
        let capped = NodePresentation(node: try node(active: 2, maxJobs: "4"), now: now, locale: en)
        XCTAssertEqual(capped.jobs, "2 of 4 transcodes")
        let uncapped = NodePresentation(node: try node(active: 2, maxJobs: "0"), now: now, locale: en)
        XCTAssertEqual(uncapped.jobs, "2 transcodes, no limit")
        let proxy = NodePresentation(node: try node(type: "proxy", active: 5, maxJobs: "null"), now: now, locale: en)
        XCTAssertEqual(proxy.jobs, "5 streams, no limit")
    }

    func testEgressAgainstTheBandwidthCap() throws {
        XCTAssertEqual(NodePresentation(node: try node(egress: 12_500, maxBandwidth: "100000"), now: now, locale: en).egress, "12.5 of 100 Mbps")
        XCTAssertEqual(NodePresentation(node: try node(egress: 12_500), now: now, locale: en).egress, "12.5 Mbps")
    }

    func testAtCapacityIsFlagged() throws {
        XCTAssertTrue(NodePresentation(node: try node(active: 4, maxJobs: "4"), now: now, locale: en).jobsAtLimit)
        XCTAssertFalse(NodePresentation(node: try node(active: 3, maxJobs: "4"), now: now, locale: en).jobsAtLimit)
    }

    // MARK: Last health check

    func testLastHealthCheck() throws {
        XCTAssertEqual(NodePresentation(node: try node(), now: now, locale: en).lastCheck, "Checked 3 min ago")
        XCTAssertEqual(NodePresentation(node: try node(checked: "null"), now: now, locale: en).lastCheck, "Never checked")
    }

    func testTypeAndGroup() throws {
        let row = NodePresentation(node: try node(), now: now, locale: en)
        XCTAssertEqual(row.typeText, "Transcode node")
        XCTAssertEqual(row.group, "rack-1")
        XCTAssertNil(NodePresentation(node: try node(group: "null"), now: now, locale: en).group)
    }
}
