import Foundation

/// The channels of Silo's events socket (`silo.events.v2`) the admin app reads. A channel only says that
/// something changed; the screen then re-reads its own REST endpoint, which stays the source of truth.
enum LiveChannel: String, CaseIterable, Sendable, Hashable {
    /// Playback sessions: Now playing, the dashboard's live tiles.
    case sessions
    /// Library scans: progress, queued, finished.
    case scans
    /// Scheduled tasks (including the backup task).
    case tasks
    /// Admin jobs (library metadata refreshes and other background jobs).
    case jobs
    /// The signed-in profile's inbox. Not used for the request badge: it carries the profile's own
    /// deliveries, not the count of requests waiting for an administrator.
    case notifications

    // The organization live socket's channels (`bloem-live.v1`, docs/design.md). They are not
    // Silo's: only a socket opened with an organization pass's ticket serves them, and the account socket refuses
    // them as unknown. `OrganizationLiveSocket` carries them over this connection's machinery.

    /// The organization's live streams.
    case orgStreams = "org.streams"
    /// Memberships: someone joined, changed role or status, or was removed.
    case orgPeople = "org.people"
    /// New entries in the organization's activity.
    case orgActivity = "org.activity"
}

/// What a screen does while its socket works but the server does not serve one of its channels (a server that has
/// not got the channel yet). It is only about that case: with no socket at all every screen falls back to one read
/// a minute, as the client rules say.
enum LiveWhenNotOffered: Equatable, Sendable {
    /// One read a minute: what the pages of Silo's own channels do.
    case slowPoll
    /// The screen read on open and on pull before it had this channel, and still does: no timer.
    case readOnOpenOnly
    /// The screen ran this timer (seconds) before it had this channel, and still does: nothing about it changes.
    case every(TimeInterval)
}

/// What a subscriber is told.
enum LiveSignal: Equatable, Hashable, Sendable {
    /// An event frame arrived on the channel.
    case changed(LiveChannel)
    /// The server sent its snapshot of the channel (after a connect, a reconnect or a new subscription).
    /// Silo has no resume, so this is the "re-read everything" cue.
    case resync(LiveChannel)
    /// The socket cannot serve this subscription (three failed connects, no socket on this server, or a
    /// channel the server refused): a poll tick, at most once a minute, only while the screen is visible.
    case fallback
    /// The ticket request was refused for the login (401 or 403); see `LiveConnection.authError`.
    case signInRequired
}

/// A clock the connection manager sleeps on and reads, so tests can run minutes in milliseconds.
protocol LiveClock: Sendable {
    /// Seconds on a monotonic clock that keeps counting while the device sleeps.
    func now() -> TimeInterval
    /// Throws `CancellationError` when the task is cancelled.
    func sleep(for seconds: TimeInterval) async throws
}

struct SystemLiveClock: LiveClock {
    private static let origin = ContinuousClock.now

    func now() -> TimeInterval {
        let elapsed = Self.origin.duration(to: ContinuousClock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(seconds, 0)))
    }
}

/// Suspends a task until it is cancelled or `resume()` is called, without a timer.
final class ParkingSpot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if released { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            resume()
        }
    }

    func resume() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
