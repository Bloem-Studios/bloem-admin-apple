import SwiftUI
import Observation

/// The organization's own live streams: who is watching what, on which device, and whether it plays directly or is
/// converted. The server sends support fields only (no address, server name or routing). On a server with the
/// organization live socket the page reads again when its `org.streams` channel says a stream changed, with no
/// timer; a server without it keeps asking again every few seconds while the page is open.
@Observable
@MainActor
final class OrganizationStreamsViewModel {
    static let pollInterval: Duration = .seconds(10)
    static let pageLimit = 100
    static let pageCap = 5

    private(set) var streams: [SupportStream] = []
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var actionError: String?
    private(set) var notice: String?
    private(set) var pendingIDs: Set<String> = []
    @ObservationIgnored private var gate = LatestRequestGate()
    @ObservationIgnored private let sequencer: PlaybackCommandSequencer

    init(sequencer: PlaybackCommandSequencer = PlaybackCommandSequencer()) {
        self.sequencer = sequencer
    }

    /// Every page of streams, up to `pageCap`.
    func load(session: OrganizationSession) async {
        let request = gate.begin()
        isLoading = streams.isEmpty
        var found: [SupportStream] = []
        var cursor: String?
        for _ in 0..<Self.pageCap {
            let page = await session.attemptRead(fallback: String(localized: "Now playing couldn't be loaded. Try again.")) {
                try await $0.listOrganizationStreams(cursor: cursor, limit: Self.pageLimit)
            }
            switch page {
            case .ok(let value):
                found += value.streams
                cursor = value.nextCursor
            case .failed(let message):
                guard gate.isCurrent(request) else { return }
                isLoading = false
                errorMessage = message
                return
            case .cancelled:
                return
            }
            if cursor == nil { break }
        }
        guard gate.isCurrent(request) else { return }
        isLoading = false
        errorMessage = nil
        streams = found
    }

    /// Loads now and then every `interval` until the task is cancelled (the page went away). This is what the page
    /// does on a server without the organization live socket, and what it keeps doing there.
    func poll(session: OrganizationSession, interval: Duration = OrganizationStreamsViewModel.pollInterval) async {
        while !Task.isCancelled {
            await load(session: session)
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    /// Keeps the list current until the task is cancelled: from the organization live socket when the server has one
    /// (no timer while it is up), otherwise by `poll`. A socket that does not serve `org.streams` is read at the same
    /// `interval`. See `OrganizationLive.follow`.
    func watch(session: OrganizationSession, connection: LiveConnection? = nil, interval: Duration = OrganizationStreamsViewModel.pollInterval) async {
        await OrganizationLive.follow(
            session: session, channel: .orgStreams, connection: connection, whenNotOffered: .every(interval.timeInterval),
            legacy: { await self.poll(session: session, interval: interval) },
            refresh: { await self.load(session: session) }
        )
    }

    func dismissMessages() {
        actionError = nil
        notice = nil
    }

    /// Stops a stream: its authority is revoked at once, then the player is told if it can be. Safe to repeat.
    func stop(session: OrganizationSession, stream: SupportStream) async {
        guard pendingIDs.insert(stream.sessionID).inserted else { return }
        defer { pendingIDs.remove(stream.sessionID) }
        dismissMessages()
        let outcome = await session.attemptWrite(fallback: String(localized: "The stream couldn't be stopped. Try again; stopping twice is safe.")) { client, _ in
            try await client.stopOrganizationStream(sessionID: stream.sessionID)
        }
        switch outcome {
        case .ok(let result):
            if result.alreadyRevoked {
                notice = String(localized: "That stream had already been stopped")
            } else if result.clientNotified {
                notice = String(localized: "Stream stopped")
            } else {
                notice = String(localized: "Stream stopped. The player wasn't told, so it may play what it already loaded.")
            }
            await load(session: session)
        case .failed(let message):
            actionError = message
            await load(session: session)
        case .cancelled:
            break
        }
    }

    /// Puts a message on the player. Answers nil once the server has it, or the text saying why not (for the sheet
    /// to show, since the page is behind it). A command identity is allocated once per message.
    func sendMessage(session: OrganizationSession, stream: SupportStream, title: String, message: String) async -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return String(localized: "Write a message first") }
        guard pendingIDs.insert(stream.sessionID).inserted else { return String(localized: "Wait for the last action on this stream to finish.") }
        defer { pendingIDs.remove(stream.sessionID) }
        dismissMessages()
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = sequencer.next(sessionId: stream.sessionID)
        let sequencer = sequencer
        let outcome = await session.attemptWrite(fallback: String(localized: "The message couldn't be confirmed")) { client, _ in
            do {
                return try await client.messageOrganizationStream(
                    sessionID: stream.sessionID, title: heading.isEmpty ? nil : heading, message: text, identity: identity
                )
            } catch let error as APIError where error.statusCode == 409 {
                // Another command reached the stream first: the next message goes above the one it applied.
                if let latest = error.latestSequence { sequencer.observe(sessionId: stream.sessionID, latest: latest) }
                throw error
            }
        }
        switch outcome {
        case .ok:
            notice = String(localized: "Message sent to \(stream.watcherLabel)")
            return nil
        case .failed(let message):
            return message
        case .cancelled:
            return String(localized: "The message couldn't be confirmed")
        }
    }
}

struct OrganizationStreamsView: View {
    let session: OrganizationSession
    @State private var model = OrganizationStreamsViewModel()
    @State private var stopping: SupportStream?
    @State private var messaging: SupportStream?

    var body: some View {
        OrganizationListFrame(
            isLoading: model.isLoading, isEmpty: model.streams.isEmpty,
            emptyTitle: String(localized: "Nothing playing"),
            emptyMessage: String(localized: "Nobody in this organization is watching anything right now"),
            emptyIcon: .monitorPlay, errorMessage: model.errorMessage ?? model.actionError, noticeMessage: model.notice,
            onRetry: { Task { await model.load(session: session) } },
            onDismissMessages: { model.dismissMessages() }
        ) {
            Section {
                ForEach(model.streams) { stream in
                    // The platform's row, with the server's routing (node, network) left out and no address.
                    StreamRowView(session: stream.playbackRow, showServerRouting: false, pending: model.pendingIDs.contains(stream.sessionID)) {
                        actions(for: stream)
                    }
                }
            } footer: {
                Text("Who is watching, what, on which device, and whether it plays directly or is converted. Addresses, server names and routing belong to the server and aren't shown.")
            }
        }
        .accessibilityIdentifier("organization-page-streams")
        .task { await model.watch(session: session) }
        .refreshable { await model.load(session: session) }
        .confirmationDialog(
            stopping.map { String(localized: "Stop \($0.title) for \($0.watcherLabel)?") } ?? "",
            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
            titleVisibility: .visible,
            presenting: stopping
        ) { stream in
            Button("Stop playback", role: .destructive) { Task { await model.stop(session: session, stream: stream) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The player is told to stop. They can start it again.")
        }
        .sheet(item: $messaging) { stream in
            OrganizationStreamMessageSheet(stream: stream) { title, message in
                await model.sendMessage(session: session, stream: stream, title: title, message: message)
            }
        }
    }

    @ViewBuilder
    private func actions(for stream: SupportStream) -> some View {
        let canStop = session.support.streams.stop && stream.canStop
        let canMessage = session.support.streams.message && stream.canMessage
        if canStop || canMessage {
            Menu {
                if canMessage {
                    Button { messaging = stream } label: { Label("Send message", icon: .messageSquareText) }
                }
                if canStop {
                    Button(role: .destructive) { stopping = stream } label: { Label("Stop playback", icon: .circleStop) }
                }
            } label: {
                RowActionsIcon()
            }
            .disabled(model.pendingIDs.contains(stream.sessionID))
            .accessibilityLabel(String(localized: "Actions for \(stream.watcherLabel)"))
            .accessibilityIdentifier("organization-stream-actions-\(stream.sessionID)")
        }
    }
}

/// A short message for the player's screen: an optional title and the text.
private struct OrganizationStreamMessageSheet: View {
    let stream: SupportStream
    /// Sends; answers nil once sent, or why not.
    let onSend: @MainActor (String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var message = ""
    @State private var isSending = false
    @State private var error: String?

    static let titleLimit = 256
    static let messageLimit = 2048

    private var isValid: Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= Self.messageLimit && title.count <= Self.titleLimit
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (optional)", text: $title)
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("organization-stream-message-text")
                } footer: {
                    Text("Shown on \(stream.device.name.isEmpty ? String(localized: "their player") : stream.device.name)")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.bloemDanger) }
                }
            }
            .navigationTitle(String(localized: "Message \(stream.watcherLabel)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isSending = true
                            error = await onSend(title, message)
                            isSending = false
                            if error == nil { dismiss() }
                        }
                    } label: {
                        if isSending { ProgressView() } else { Text("Send") }
                    }
                    .disabled(isSending || !isValid)
                }
            }
        }
        .interactiveDismissDisabled(isSending)
    }
}
