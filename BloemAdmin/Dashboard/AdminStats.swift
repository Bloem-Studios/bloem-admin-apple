import Foundation

/// `GET /api/v2/admin/stats`: the catalog numbers behind the Movies, Shows and Storage tiles. The
/// response carries more (users, items, watch providers); the dashboard shows only these, and the
/// rest is ignored on decode.
struct AdminStats: Decodable, Sendable, Equatable {
    let totalFiles: Int
    let totalMovies: Int
    let totalMovieFiles: Int
    let totalShows: Int
    let totalShowFiles: Int
    let totalStorageBytes: Int64

    init(
        totalFiles: Int, totalMovies: Int, totalMovieFiles: Int,
        totalShows: Int, totalShowFiles: Int, totalStorageBytes: Int64
    ) {
        self.totalFiles = totalFiles
        self.totalMovies = totalMovies
        self.totalMovieFiles = totalMovieFiles
        self.totalShows = totalShows
        self.totalShowFiles = totalShowFiles
        self.totalStorageBytes = totalStorageBytes
    }

    enum CodingKeys: String, CodingKey {
        case totalFiles = "total_files"
        case totalMovies = "total_movies"
        case totalMovieFiles = "total_movie_files"
        case totalShows = "total_shows"
        case totalShowFiles = "total_show_files"
        case totalStorageBytes = "total_storage_bytes"
    }
}

/// `GET /api/v2/admin/system/resources`: the API host's last resource sample. Always 200;
/// `available:false` means there is no sample to show (the card is hidden, not an error), and
/// `stale:true` means `system` is the last good sample rather than a fresh one.
struct SystemResources: Decodable, Sendable {
    let available: Bool
    let stale: Bool
    let sampledAt: Date?
    let system: SystemStats?

    enum CodingKeys: String, CodingKey {
        case available, stale, system
        case sampledAt = "sampled_at"
    }

    /// The sample to draw, or nil when the card should be hidden.
    var visibleSystem: SystemStats? { available ? system : nil }
}

struct SystemStats: Decodable, Sendable {
    /// Sent as a whole or fractional percentage; either decodes.
    let cpuPct: Double
    let cores: Int
    let memUsedMB: Int64
    let memTotalMB: Int64
    /// The contract reports network rates in bits per second.
    let netRxBps: Double
    let netTxBps: Double

    enum CodingKeys: String, CodingKey {
        case cpuPct = "cpu_pct"
        case cores
        case memUsedMB = "mem_used_mb"
        case memTotalMB = "mem_total_mb"
        case netRxBps = "net_rx_bps"
        case netTxBps = "net_tx_bps"
    }

    /// The screen shows bytes per second.
    var netRxBytesPerSec: Double { netRxBps / 8 }
    var netTxBytesPerSec: Double { netTxBps / 8 }
    var memUsedBytes: Int64 { memUsedMB * 1_048_576 }
    var memTotalBytes: Int64 { memTotalMB * 1_048_576 }
}
