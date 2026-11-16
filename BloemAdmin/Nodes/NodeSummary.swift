import Foundation

struct NodeDisk: Decodable, Equatable, Sendable {
    let usedGb: Double
    let totalGb: Double
    let unavailable: Bool?

    enum CodingKeys: String, CodingKey {
        case usedGb = "used_gb"
        case totalGb = "total_gb"
        case unavailable
    }
}

/// The host sample of a node: `resources.system` of `GET /api/v2/admin/nodes/summary`.
struct NodeSystem: Decodable, Equatable, Sendable {
    let cpuPct: Int
    let cores: Int
    let memUsedMb: Int
    let memTotalMb: Int
    let disks: [NodeDisk]
    let netRxBps: Int
    let netTxBps: Int

    enum CodingKeys: String, CodingKey {
        case cores, disks
        case cpuPct = "cpu_pct"
        case memUsedMb = "mem_used_mb"
        case memTotalMb = "mem_total_mb"
        case netRxBps = "net_rx_bps"
        case netTxBps = "net_tx_bps"
    }
}

struct NodeResources: Decodable, Equatable, Sendable {
    struct Attribution: Decodable, Equatable, Sendable {
        let sampleIntervalSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case sampleIntervalSeconds = "sample_interval_seconds"
        }
    }

    let sampledAt: String?
    let attribution: Attribution?
    let system: NodeSystem?

    enum CodingKeys: String, CodingKey {
        case attribution, system
        case sampledAt = "sampled_at"
    }
}

/// One node of `GET /api/v2/admin/nodes/summary`: health, drain state, load and capacity, without
/// addresses or paths.
struct NodeSummary: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// `transcode` or `proxy`.
    let type: String
    let enabled: Bool
    let healthy: Bool
    let group: String?
    /// `none`, `draining` or `drained`.
    let drainState: String
    let drainRequested: Bool
    let activeJobs: Int
    /// At or below zero, or absent, means no limit.
    let maxJobs: Int?
    let egressKbps: Int
    let maxBandwidthKbps: Int?
    let lastHealthCheck: String?
    let resources: NodeResources?

    enum CodingKeys: String, CodingKey {
        case id, name, type, enabled, healthy, group, resources
        case drainState = "drain_state"
        case drainRequested = "drain_requested"
        case activeJobs = "active_jobs"
        case maxJobs = "max_jobs"
        case egressKbps = "egress_kbps"
        case maxBandwidthKbps = "max_bandwidth_kbps"
        case lastHealthCheck = "last_health_check"
    }
}

enum NodeState: Equatable, Sendable {
    case healthy, draining, drained, unhealthy, disabled

    /// How the state word is said: an unhealthy node in the failure colour with a dot, one being drained in the warning
    /// colour with a dot, the rest quietly.
    var statusTone: StatusLabel.Tone {
        switch self {
        case .unhealthy: .failure
        case .draining, .drained: .warning
        case .healthy: .positive
        case .disabled: .normal
        }
    }
}

/// The load readings of a node, in words and figures.
struct NodeLoadReadings: Equatable {
    let cpu: String
    let memory: String
    let disk: String?
    let diskWarning: Bool
    let network: String
}

/// What the Nodes page says about one node. Disabled beats unhealthy, which beats draining, as on the
/// web. The clock is injected so an out-of-date sample is testable.
struct NodePresentation: Equatable {
    static let diskWarningPercent = 85

    let name: String
    let typeText: String
    let group: String?
    let state: NodeState
    let stateText: String
    let drainLabel: String?
    let drainDetail: String?
    let canDrain: Bool
    let canResume: Bool
    let enableActionTitle: String
    let load: NodeLoadReadings?
    /// Why there are no load readings: no sample yet, or one that is out of date.
    let loadUnavailable: String?
    let jobs: String
    let jobsAtLimit: Bool
    let egress: String
    let lastCheck: String

    init(node: NodeSummary, now: Date, locale: Locale = .current) {
        name = node.name
        let isTranscode = node.type == "transcode"
        typeText = isTranscode ? String(localized: "Transcode node") : String(localized: "Proxy node")
        group = node.group.flatMap { $0.isEmpty ? nil : $0 }
        enableActionTitle = node.enabled ? String(localized: "Disable") : String(localized: "Enable")
        canDrain = isTranscode && node.enabled && !node.drainRequested
        canResume = isTranscode && node.drainRequested

        let drain = Self.drain(node: node, isTranscode: isTranscode)
        drainLabel = drain?.label
        drainDetail = drain?.detail
        if !node.enabled {
            state = .disabled
            stateText = String(localized: "Disabled")
        } else if !node.healthy {
            state = .unhealthy
            stateText = String(localized: "Unhealthy")
        } else if let phase = drain?.phase {
            state = phase
            stateText = phase == .drained ? String(localized: "Drained") : String(localized: "Draining")
        } else {
            state = .healthy
            stateText = String(localized: "Healthy")
        }

        let readings = Self.load(resources: node.resources, now: now, locale: locale)
        load = readings.load
        loadUnavailable = readings.unavailable

        let cap = node.maxJobs.flatMap { $0 > 0 ? $0 : nil }
        let active = max(0, node.activeJobs)
        let unit = isTranscode ? String(localized: "transcodes") : String(localized: "streams")
        if let cap {
            jobs = String(localized: "\(active) of \(cap) \(unit)")
        } else {
            jobs = String(localized: "\(active) \(unit), no limit")
        }
        jobsAtLimit = cap.map { active >= $0 } ?? false

        let used = Self.mbps(kbps: max(0, node.egressKbps), locale: locale)
        if let bandwidth = node.maxBandwidthKbps.flatMap({ $0 > 0 ? $0 : nil }) {
            egress = String(localized: "\(used) of \(Self.mbps(kbps: bandwidth, locale: locale)) Mbps")
        } else {
            egress = String(localized: "\(used) Mbps")
        }

        if let checked = AdminTimestamp.date(from: node.lastHealthCheck) {
            lastCheck = String(localized: "Checked \(formatRelativeTime(checked, now: now))")
        } else {
            lastCheck = String(localized: "Never checked")
        }
    }

    private struct Drain {
        let phase: NodeState
        let label: String
        let detail: String
    }

    private static func drain(node: NodeSummary, isTranscode: Bool) -> Drain? {
        guard isTranscode else { return nil }
        let requested = node.drainRequested
        if !node.enabled {
            return requested
                ? Drain(
                    phase: .draining, label: String(localized: "Drain requested"),
                    detail: String(localized: "The node is disabled. It stays out of new placement when it is enabled again until it is resumed")
                )
                : nil
        }
        if !requested && node.drainState == "none" { return nil }
        if !node.healthy {
            return requested
                ? Drain(
                    phase: .draining, label: String(localized: "Draining, not answering"),
                    detail: String(localized: "Drain requested, but the node did not answer its last health check. New work stays off it")
                )
                : nil
        }
        if node.drainState == "drained" {
            return requested
                ? Drain(
                    phase: .drained, label: String(localized: "Drained, safe to stop"),
                    detail: String(localized: "No sessions or jobs are left on this node. Resume it to take new work again")
                )
                : Drain(
                    phase: .drained, label: String(localized: "Drained, no work left"),
                    detail: String(localized: "The node takes no new work. A node that was told to stop exits now")
                )
        }
        let active = max(0, node.activeJobs)
        let label = active == 1
            ? String(localized: "Draining, 1 job still running")
            : String(localized: "Draining, \(active) jobs still running")
        return Drain(
            phase: .draining, label: label,
            detail: requested
                ? String(localized: "New work goes to other nodes. Sessions already here keep playing until they end")
                : String(localized: "The node takes no new work. A node that was told to stop exits when its sessions end or its drain timeout passes")
        )
    }

    private static func load(resources: NodeResources?, now: Date, locale: Locale) -> (load: NodeLoadReadings?, unavailable: String?) {
        guard let system = resources?.system else {
            return (nil, String(localized: "No resource sample yet"))
        }
        if let attribution = resources?.attribution {
            let sampled = AdminTimestamp.date(from: resources?.sampledAt)
            let interval = attribution.sampleIntervalSeconds ?? 5
            if sampled == nil || now.timeIntervalSince(sampled!) > interval * 3 {
                return (nil, String(localized: "The last resource sample is out of date"))
            }
        }
        let gb: (Int) -> String = { $0 == 0 ? "0.0" : (Double($0) / 1024).formatted(.number.precision(.fractionLength(1)).locale(locale)) }
        let memory = String(localized: "\(gb(system.memUsedMb)) of \(gb(system.memTotalMb)) GB")

        let fills = system.disks.filter { $0.unavailable != true && $0.totalGb > 0 }.map { Int(($0.usedGb / $0.totalGb * 100).rounded()) }
        let worst = fills.max()
        let network = String(
            localized: "In \(mbps(bps: system.netRxBps, locale: locale)) Mbps, out \(mbps(bps: system.netTxBps, locale: locale)) Mbps"
        )
        return (
            NodeLoadReadings(
                cpu: "\(system.cpuPct)%", memory: memory,
                disk: worst.map { String(localized: "\($0)% used") },
                diskWarning: (worst ?? 0) >= diskWarningPercent, network: network
            ),
            nil
        )
    }

    private static func mbps(kbps: Int, locale: Locale) -> String {
        (Double(kbps) / 1000).formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }

    private static func mbps(bps: Int, locale: Locale) -> String {
        (Double(bps) / 1_000_000).formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }
}
