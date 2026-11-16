import SwiftUI

/// One stream row with its controls: a menu in the row's corner with Pause or Resume, Stop playback, Send
/// message and End stream. It owns the confirmations, the message sheet and the in-flight gate, so the single
/// server page and each server's section of All Servers draw the same thing.
struct StreamControlledRow: View {
    let session: AdminSession
    let client: APIClient
    let viewModel: StreamsViewModel
    /// The platform administrator's pages pass true; an organization context never does.
    var showClientIP = false
    /// Opens Logs for this stream's playback session ("Logs", "FFmpeg logs"). Only the single-server
    /// page passes it: Logs is not part of All servers or an organization.
    var onOpenLogs: ((LogsFocus) -> Void)?
    /// Runs after a command changed the stream. The default re-reads this server's list.
    var refreshAfterMutation: (@MainActor () async -> Void)?

    @Environment(\.adminSessionState) private var sessionState
    @State private var showingTerminateConfirm = false
    @State private var showingStopConfirm = false
    @State private var showingMessageSheet = false
    @State private var mutationGate = PrivilegedMutationGate()
    /// Set on a successful message, cleared as soon as any other action runs: a transient
    /// confirmation, never persistent state.
    @State private var messageSentConfirmation = false
    /// Toggled on a successful Terminate; drives the haptic.
    @State private var terminateSucceeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StreamRowView(session: session, showClientIP: showClientIP, pending: mutationGate.isActive) {
                controlsMenu
            }
            if messageSentConfirmation {
                Text("Message sent").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
        }
        .confirmationDialog(
            "Stop \(session.mediaTitle) for \(session.username)?",
            isPresented: $showingStopConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop playback", role: .destructive) { Task { await stopPlayback() } }
                .disabled(mutationGate.isActive)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The player is told to stop. They can start it again.")
        }
        .confirmationDialog(
            "End \(session.username)'s stream of \(session.mediaTitle)?",
            isPresented: $showingTerminateConfirm,
            titleVisibility: .visible
        ) {
            Button("End stream", role: .destructive) { Task { await terminate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The server closes the session now, even if the player does not stop. It cannot be resumed.")
        }
        .sheet(isPresented: $showingMessageSheet) {
            MessageSessionView(session: session, client: client, viewModel: viewModel, mutationGate: $mutationGate) {
                messageSentConfirmation = true
            }
        }
        .sensoryFeedback(.success, trigger: terminateSucceeded)
    }

    private var controlsMenu: some View {
        Menu {
            Button(session.isPaused ? "Resume" : "Pause") { Task { await togglePause() } }
            Button("Stop playback") { showingStopConfirm = true }
            Button("Send message") {
                messageSentConfirmation = false
                showingMessageSheet = true
            }
            if let onOpenLogs {
                Button("Logs") { onOpenLogs(LogsFocus(playbackSessionID: session.sessionID, ffmpegOnly: false)) }
                Button("FFmpeg logs") { onOpenLogs(LogsFocus(playbackSessionID: session.sessionID, ffmpegOnly: true)) }
            }
            Button("End stream", role: .destructive) { showingTerminateConfirm = true }
        } label: {
            RowActionsIcon()
        }
        .disabled(mutationGate.isActive)
        .accessibilityLabel("Actions for \(session.username)")
        .accessibilityIdentifier("stream-actions.\(session.sessionID)")
    }

    private func togglePause() async {
        guard mutationGate.begin() else { return }
        defer { mutationGate.end() }
        messageSentConfirmation = false
        if session.isPaused {
            await viewModel.resume(session, client: client, sessionState: sessionState)
        } else {
            await viewModel.pause(session, client: client, sessionState: sessionState)
        }
        if viewModel.actionErrorMessage == nil { await refreshList() }
    }

    private func stopPlayback() async {
        guard mutationGate.begin() else { return }
        defer { mutationGate.end() }
        messageSentConfirmation = false
        await viewModel.stop(session, client: client, sessionState: sessionState)
        if viewModel.actionErrorMessage == nil { await refreshList() }
    }

    private func terminate() async {
        guard mutationGate.begin() else { return }
        defer { mutationGate.end() }
        messageSentConfirmation = false
        await viewModel.terminate(session, client: client, sessionState: sessionState)
        if viewModel.actionErrorMessage == nil {
            terminateSucceeded.toggle()
            await refreshList()
        }
    }

    private func refreshList() async {
        if let refreshAfterMutation {
            await refreshAfterMutation()
        } else {
            await viewModel.load(client: client, sessionState: sessionState)
        }
    }
}

/// A failed command, kept visible until dismissed or replaced by a newer one.
struct StreamActionErrorRow: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).foregroundStyle(.bloemDanger)
            Button("Dismiss", action: onDismiss)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sheet form for `POST /api/v2/admin/sessions/{id}/message`, mirroring `EditUserQuotasView`'s "small
/// form as a modal" shape (NavigationStack + Form + cancel/confirm toolbar actions, shared mutation
/// gate plus local `errorMessage` state, dismissing itself on success). Title is optional; Send
/// stays disabled until `message` is non-empty, mirroring the server's own 400-on-blank-message
/// contract client-side.
struct MessageSessionView: View {
    let session: AdminSession
    let client: APIClient
    let viewModel: StreamsViewModel
    @Binding var mutationGate: PrivilegedMutationGate
    /// Invoked once, right before dismissing, on a successful send, so the row can show its own
    /// brief confirmation without this sheet knowing how it is displayed.
    let onSent: () -> Void

    @Environment(\.adminSessionState) private var sessionState
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var message = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Message") {
                    TextField("Title (optional)", text: $title)
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3...6)
                }
                .disabled(mutationGate.isActive)
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.bloemDanger)
                    }
                }
            }
            .navigationTitle("Message \(session.username)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(mutationGate.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        mutationGate.submit {
                            Task { await send() }
                        }
                    } label: {
                        if mutationGate.isActive {
                            ProgressView()
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(mutationGate.isActive || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(mutationGate.isActive)
    }

    private func send() async {
        defer { mutationGate.end() }
        errorMessage = nil
        let response = await viewModel.sendMessage(to: session, title: title, message: message, client: client, sessionState: sessionState)
        guard response != nil else {
            errorMessage = viewModel.actionErrorMessage
            return
        }
        onSent()
        dismiss()
    }
}
