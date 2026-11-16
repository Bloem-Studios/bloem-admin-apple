import SwiftUI

/// One request's details, as the web admin's request dialog: the title, its state and dates, who asked,
/// where each quality went, the overview, the history, and the actions its view allows.
struct RequestDetailView: View {
    let request: MediaRequest
    let client: APIClient
    let requester: String
    /// Set in All Servers mode, where the sheet says which server the request belongs to.
    var serverName: String?
    /// Runs an action and reports whether the server took it.
    let perform: @MainActor (RequestQueueAction, String?) async -> Bool
    /// The latest refused action's message, read after `perform` returns false.
    var actionError: @MainActor () -> String? = { nil }

    @Environment(\.dismiss) private var dismiss
    @State private var events: [RequestEvent] = []
    @State private var eventsFailed = false
    @State private var eventsLoaded = false
    @State private var prompt: RequestReasonPrompt?
    @State private var note = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    RequestPoster(path: request.posterPath, size: "w185").frame(width: 72)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.title).bloemText(.titleLarge)
                        Text(RequestQueue.metaLine(request)).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                        RequestStateSummary(request: request)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Request") {
                if let state = RequestQueue.displayState(request) {
                    LabeledContent("State") { RequestBadge(text: state.label, tone: state.tone) }
                }
                if let serverName {
                    LabeledContent("Server", value: serverName)
                }
                LabeledContent("Requested by", value: requester)
                if let created = request.createdAt {
                    LabeledContent("Requested", value: created.formatted(date: .abbreviated, time: .shortened))
                }
                if let approved = request.approvedAt {
                    LabeledContent("Approved", value: approved.formatted(date: .abbreviated, time: .shortened))
                }
                if let completed = request.completedAt {
                    LabeledContent("Completed", value: completed.formatted(date: .abbreviated, time: .shortened))
                }
                if request.mediaType == "series" {
                    LabeledContent("Seasons", value: RequestQueue.seasonList(request.seasons) ?? String(localized: "Whole series"))
                }
                if let tmdb = request.tmdbID {
                    LabeledContent("TMDB ID", value: String(tmdb))
                }
                if request.source == "watchlist" {
                    Text("via watchlist").foregroundStyle(.bloemMuted)
                }
            }
            Section("Servers") {
                RequestTargetList(request: request)
            }
            if let overview = request.overview {
                Section {
                    Text(overview).bloemText(.bodyLarge)
                }
            }
            Section("History") {
                if !eventsLoaded {
                    ProgressView()
                } else if eventsFailed {
                    Text("The history couldn't be loaded. Try again.").foregroundStyle(.bloemMuted)
                } else if events.isEmpty {
                    Text("No history yet").foregroundStyle(.bloemMuted)
                } else {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(RequestQueue.eventLabel(event.type)).bloemText(.titleSmall)
                            Text(eventDetail(event)).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                            if let message = event.message, !message.isEmpty {
                                Text(message).bloemText(.bodySmall)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            let actions = RequestQueue.actions(for: request)
            if !actions.isEmpty {
                Section {
                    ForEach(actions) { action in
                        Button(role: action.asksForReason ? .destructive : nil) {
                            run(action)
                        } label: {
                            Label(action.label, icon: action.icon)
                        }
                        .disabled(busy)
                    }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.bloemDanger)
                    }
                }
            }
        }
        .navigationTitle(request.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task(id: request.id) { await loadEvents() }
        .requestReasonAlert($prompt, note: $note) { prompt, reason in
            Task { await finish(prompt.action, reason: reason) }
        }
    }

    private func eventDetail(_ event: RequestEvent) -> String {
        var parts: [String] = []
        if let date = event.createdAt { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let actor = event.actorUsername, !actor.isEmpty { parts.append(actor) }
        return parts.joined(separator: " · ")
    }

    private func loadEvents() async {
        do {
            events = try await client.requestEvents(id: request.id)
            eventsFailed = false
        } catch {
            eventsFailed = true
        }
        eventsLoaded = true
    }

    private func run(_ action: RequestQueueAction) {
        if action.asksForReason {
            note = ""
            prompt = RequestReasonPrompt(action: action, request: request)
        } else {
            Task { await finish(action, reason: nil) }
        }
    }

    private func finish(_ action: RequestQueueAction, reason: String?) async {
        busy = true
        defer { busy = false }
        if await perform(action, reason) {
            errorMessage = nil
            dismiss()
        } else {
            errorMessage = actionError() ?? String(localized: "The action didn't go through. Try again.")
        }
    }
}
