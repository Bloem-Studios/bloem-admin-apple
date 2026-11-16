import Foundation

/// Identifies one playback command. The server refuses a sequence below the latest it applied.
struct PlaybackCommandIdentity: Equatable, Sendable {
    let commandID: String
    let sequence: Int64
}

/// Allocates command identities for one owner (a view model). Sequences follow the wall clock so
/// they keep rising across app launches, and rise by at least one per session within a run. A
/// failed command is never retried here: the next attempt asks for a new identity.
final class PlaybackCommandSequencer: @unchecked Sendable {
    /// 2^53 - 1: the largest sequence every client can represent exactly.
    static let maxSequence: Int64 = 9_007_199_254_740_991

    private let clock: @Sendable () -> Int64
    private let lock = NSLock()
    private var last: [String: Int64] = [:]

    init(clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.clock = clock
    }

    func next(sessionId: String) -> PlaybackCommandIdentity {
        lock.lock()
        defer { lock.unlock() }
        let previous = last[sessionId] ?? 0
        let sequence = min(Self.maxSequence, max(clock(), previous + 1))
        last[sessionId] = sequence
        return PlaybackCommandIdentity(commandID: UUID().uuidString.lowercased(), sequence: sequence)
    }

    /// The server reported `latest` as applied for this session; the next allocation goes above it.
    func observe(sessionId: String, latest: Int64) {
        lock.lock()
        defer { lock.unlock() }
        last[sessionId] = max(last[sessionId] ?? 0, min(latest, Self.maxSequence))
    }
}
