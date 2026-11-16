import SwiftUI

/// A request's TMDB poster, or a plain tile when it has none.
struct RequestPoster: View {
    let path: String?
    var size = "w92"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.inner).fill(Theme.raised)
            if let url = RequestQueue.posterURL(path, size: size) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        IconImage(.film, size: .row).foregroundStyle(.bloemMuted)
                    }
                }
            } else {
                IconImage(.film, size: .row).foregroundStyle(.bloemMuted)
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inner))
        .accessibilityHidden(true)
    }
}

/// A request's state in words: quiet text, with a dot only when it failed.
struct RequestBadge: View {
    let text: String
    let tone: RequestDisplayState.Tone

    var body: some View {
        StatusLabel(text, tone: tone == .danger ? .failure : .normal)
    }
}

/// The state a requester sees, with the reason it closed or the error that stopped it.
struct RequestStateSummary: View {
    let request: MediaRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let state = RequestQueue.displayState(request) {
                RequestBadge(text: state.label, tone: state.tone)
            }
            if let problem = RequestQueue.problem(request) {
                Text(problem.text)
                    .bloemText(.bodySmall)
                    .foregroundStyle(problem.isError ? Theme.danger : Theme.muted)
                    .lineLimit(3)
            }
        }
    }
}

/// Where each quality went: the download server, its status, the rule that sent it there, the
/// download's progress and the server's error.
struct RequestTargetList: View {
    let request: MediaRequest

    var body: some View {
        if request.targets.isEmpty {
            Text("Not sent to a server").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(request.targets) { target in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(target.quality).bloemText(.labelMedium)
                            Text(RequestQueue.targetServerName(target)).bloemText(.bodySmall)
                            RequestBadge(text: RequestQueue.targetStatusLabel(target.status),
                                         tone: target.status == "failed" ? .danger : .neutral)
                        }
                        if let route = target.routeName, !route.isEmpty {
                            Text("by \(route)").bloemText(.labelSmall).foregroundStyle(.bloemMuted)
                        }
                        if let download = target.download {
                            RequestDownloadLine(download: download)
                        }
                        if let error = target.lastError, !error.isEmpty {
                            Text(error).bloemText(.labelSmall).foregroundStyle(.bloemDanger).lineLimit(2)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct RequestDownloadLine: View {
    let download: RequestDownload

    var body: some View {
        let label = RequestQueue.downloadPhaseLabel(download.phase)
        if let percent = RequestQueue.downloadPercent(download) {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(percent), total: 100)
                    .frame(maxWidth: 220)
                    .accessibilityLabel(label)
                    .accessibilityValue(Text(Double(percent) / 100, format: .percent))
                Text(verbatim: "\(label) · \((Double(percent) / 100).formatted(.percent))").bloemText(.labelSmall).foregroundStyle(.bloemMuted)
            }
        } else {
            Text(label).bloemText(.labelSmall).foregroundStyle(.bloemMuted)
        }
    }
}

/// One request in the queue: poster, title, what it is, who asked and when, its state, where it went,
/// and the actions its view allows. Tapping the request opens its details.
struct RequestQueueRow: View {
    let request: MediaRequest
    let requester: String
    var busy = false
    let onAction: (RequestQueueAction) -> Void
    let onOpen: () -> Void
    /// Shows only this account's requests; nil where the queue has no such filter.
    var onFilterUser: (() -> Void)?
    /// Set while select mode is on: the row then toggles instead of opening, and its buttons wait.
    var selection: RequestRowSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: selection?.toggle ?? onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    if let selection { RequestSelectionMark(isSelected: selection.isSelected) }
                    RequestPoster(path: request.posterPath).frame(width: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.title).bloemText(.titleMedium).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Text(RequestQueue.metaLine(request)).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        Text(requestedLine).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        RequestStateSummary(request: request)
                        RequestTargetList(request: request)
                    }
                    Spacer(minLength: 0)
                    if selection == nil {
                        IconImage(.chevronRight, size: .inline).foregroundStyle(.bloemMuted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(selection == nil ? Text("Shows the request's details") : Text("Selects or deselects the request"))
            .accessibilityAddTraits(selection?.isSelected == true ? .isSelected : [])
            .accessibilityIdentifier("request-row-\(request.id)")
            let actions = selection == nil ? RequestQueue.actions(for: request) : []
            if !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(actions) { action in
                        Button { onAction(action) } label: {
                            Label(action.label, icon: action.icon)
                                .frame(minHeight: Theme.minimumTarget)
                        }
                        .buttonStyle(.bloemSecondary)
                        .accessibilityLabel(Text("\(action.label): \(request.title)"))
                    }
                    if busy { ProgressView().padding(.leading, 4) }
                }
                .disabled(busy)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let onFilterUser, request.requestedByUserID != nil {
                Button(action: onFilterUser) { Label("Show only this account's requests", icon: .circleUser) }
            }
        }
    }

    private var requestedLine: String {
        var parts = [requester]
        if let ago = RequestQueue.requestedAgo(request.createdAt) { parts.append(ago) }
        if request.source == "watchlist" { parts.append(String(localized: "via watchlist")) }
        return parts.joined(separator: " · ")
    }
}

/// The queue's four views with their counts, as a row of buttons that scrolls sideways.
struct RequestViewPicker: View {
    let selection: RequestQueueView
    let counts: RequestCounts?
    let onSelect: (RequestQueueView) -> Void

    var body: some View {
        ScrollingTabs(
            items: Array(RequestQueueView.allCases), selection: selection,
            title: { $0.label },
            count: { counts?[$0] },
            identifier: { "request-view-\($0.rawValue)" },
            onSelect: onSelect
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Request views"))
    }
}

/// What a decline, cancel or close asks before it runs: an optional note.
struct RequestReasonPrompt: Identifiable {
    let action: RequestQueueAction
    let request: MediaRequest
    var id: String { "\(action.rawValue)-\(request.id)" }
}

extension View {
    /// The web's reason dialog as an alert with a note field. `onConfirm` gets the note.
    func requestReasonAlert(
        _ prompt: Binding<RequestReasonPrompt?>, note: Binding<String>,
        onConfirm: @escaping (RequestReasonPrompt, String) -> Void
    ) -> some View {
        let text = prompt.wrappedValue.flatMap { RequestQueue.reasonPrompt($0.action, request: $0.request) }
        return alert(
            text?.title ?? "",
            isPresented: Binding(get: { prompt.wrappedValue != nil }, set: { if !$0 { prompt.wrappedValue = nil } }),
            presenting: prompt.wrappedValue
        ) { current in
            TextField("Reason (optional)", text: note)
            Button(text?.confirm ?? "", role: .destructive) {
                let entered = note.wrappedValue
                note.wrappedValue = ""
                onConfirm(current, entered)
            }
            Button("Keep request", role: .cancel) { note.wrappedValue = "" }
        } message: { _ in
            Text(text?.message ?? "")
        }
    }
}
