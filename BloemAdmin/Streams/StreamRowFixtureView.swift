#if DEBUG
import SwiftUI

/// A page of stream rows with fixed data, shown instead of the server list when the app is launched
/// with `--ui-testing-stream-rows`. UI tests use it to drive the row and its details without a
/// server. Its clock moves only when told to, and nothing here tells it, so the numbers on screen are
/// the same on every run.
struct StreamRowFixtureView: View {
    static let launchArgument = "--ui-testing-stream-rows"
    /// Given together with `launchArgument`, opens the progress page instead of the rows, so the
    /// app's entry point needs no second check.
    static let progressArgument = "--ui-testing-stream-progress"

    @State private var platformAdmin = false
    @State private var taps = 0
    private let clock = ManualStreamTickClock()

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains(Self.progressArgument) {
            StreamProgressFixtureView()
        } else {
            rows
        }
    }

    private var rows: some View {
        NavigationStack {
            // A plain stack, not a List: every row is in the accessibility tree at once.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Platform administrator", isOn: $platformAdmin)
                    Text("Corner taps: \(taps)").accessibilityIdentifier("fixture-corner-taps")
                    ForEach(Self.sessions) { session in
                        StreamRowView(session: session, showClientIP: platformAdmin) {
                            Button { taps += 1 } label: {
                                RowActionsIcon()
                            }
                            .accessibilityLabel("Actions for \(session.username)")
                            .accessibilityIdentifier("stream-actions.\(session.sessionID)")
                        }
                        Divider()
                    }
                    Text("Preview").bloemText(.titleMedium)
                    // A preview row (the dashboard's Now playing) is a summary without details.
                    StreamRowView(session: Self.preview, expandable: false)
                }
                .padding(.horizontal, 16)
            }
            .bloemPageBackground()
            .navigationTitle("Now playing")
        }
        .environment(\.streamTickClockProvider, StreamTickClockProvider { [clock] in clock })
    }

    static var preview: AdminSession {
        var copy = sessions[1]
        copy.sessionID = "preview"
        return copy
    }

    static let sessions: [AdminSession] = {
        var episode = AdminSession(
            sessionID: "ep", username: "alex", mediaTitle: "Who Is Alive?", mediaType: "episode", playMethod: "transcode",
            positionSeconds: 754, fileDuration: 2652, isPaused: false, clientName: "Silo Android"
        )
        episode.profileName = "Living room"; episode.devicePlatform = "android"
        episode.clientLabel = "Silo Android 1.4.2"; episode.clientLabelFull = "Silo Android 1.4.2 (88) beta"
        episode.clientIP = "203.0.113.9"; episode.streamBitrateKbps = 8200
        episode.videoDecision = "transcode"; episode.audioDecision = "transcode"; episode.effectivePlayMethod = "transcode"
        episode.transcodeHWAccel = "nvenc"; episode.toneMapMode = "hardware"
        episode.sourceVideoCodec = "hevc"; episode.sourceVideoResolution = "2160p"
        episode.targetVideoCodec = "h264"; episode.targetResolution = "1080p"
        episode.sourceAudioCodec = "truehd"; episode.sourceAudioChannels = 8; episode.sourceAudioLanguage = "en"
        episode.targetAudioCodec = "aac"; episode.targetAudioChannels = 6
        episode.seriesName = "Severance"; episode.episodeName = "Who Is Alive?"; episode.seasonNumber = 2; episode.episodeNumber = 3
        episode.sourceContainer = "mkv"; episode.sourceBitrateKbps = 24_500
        episode.outputContainer = "mpegts"; episode.outputProtocol = "hls"; episode.streamLocation = "remote"
        episode.startedAt = "2026-11-13T14:02:30Z"; episode.updatedAt = "2026-11-13T14:14:50Z"
        episode.routingWorkload = "video_transcode"; episode.routingExecution = "transcode"
        episode.routingExecutionNodeName = "gpu-1"; episode.routingEgress = "api"; episode.reportingNode = "main"

        var film = AdminSession(
            sessionID: "film", username: "amy", mediaTitle: "The River", mediaType: "movie", playMethod: "direct",
            positionSeconds: 1200, fileDuration: 5400, isPaused: true, clientName: "Web"
        )
        film.videoDecision = "direct"; film.audioDecision = "direct"; film.effectivePlayMethod = "direct"
        film.sourceVideoCodec = "h264"; film.sourceVideoResolution = "1920x1080"
        film.sourceAudioCodec = "eac3"; film.sourceAudioChannels = 6

        let bare = AdminSession(
            sessionID: "bare", username: "kim", mediaTitle: "Live channel", mediaType: "movie", playMethod: "",
            positionSeconds: 61, fileDuration: nil, isPaused: false, clientName: nil
        )
        return [episode, film, bare]
    }()
}

/// One stream's progress readout, the one every row embeds, on its own page for the UI tests
/// (`--ui-testing-stream-rows --ui-testing-stream-progress`). Its clock moves only on **Advance clock
/// 3 s**, and the buttons below stand in for the server's polls.
struct StreamProgressFixtureView: View {
    @State private var session: AdminSession = {
        var session = AdminSession(
            sessionID: "tick", username: "alex", mediaTitle: "Film", mediaType: "movie", playMethod: "direct",
            positionSeconds: 10, fileDuration: 100, isPaused: false, clientName: nil
        )
        session.updatedAt = "2026-11-13T14:00:00Z"
        return session
    }()
    private let clock = ManualStreamTickClock()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                StreamProgressView(session: session)
                Button("Advance clock 3 s") { clock.advance(by: 3) }
                Button("Report 0:20") { report(position: 20, paused: false) }
                Button("Report paused at 0:30") { report(position: 30, paused: true) }
                Spacer()
            }
            .padding(16)
            .navigationTitle("Progress")
        }
        .environment(\.streamTickClockProvider, StreamTickClockProvider { [clock] in clock })
    }

    private func report(position: Double, paused: Bool) {
        session.positionSeconds = position
        session.isPaused = paused
        session.updatedAt = "2026-11-13T14:00:\(Int(position))Z"
    }
}

/// A clock that moves only when told to. A sleep waits until `advance(by:)` or until its task is
/// cancelled.
@MainActor
final class ManualStreamTickClock: StreamTickClock {
    private var current: TimeInterval = 0
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]

    func now() -> TimeInterval { current }

    func sleep(for seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(
            operation: { () async throws -> Void in try await self.suspend(id) },
            onCancel: { [self] in Task { @MainActor in self.cancelSleep(id) } }
        )
    }

    /// Moves time on and wakes every sleeper.
    func advance(by seconds: TimeInterval) {
        current += seconds
        let waiting = sleepers
        sleepers.removeAll()
        for continuation in waiting.values { continuation.resume() }
    }

    private func suspend(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                sleepers[id] = continuation
            }
        }
    }

    private func cancelSleep(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
#endif
