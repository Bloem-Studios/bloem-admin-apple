import SwiftUI

/// The Nodes page of one server: every node with its state, load, capacity and last health check, and
/// Drain and Resume, Enable and Disable, each after a confirmation.
struct NodesView: View {
    let client: APIClient
    @State private var model = SectionModel<[NodeSummary]>.nodes()

    var body: some View {
        List {
            ActionErrorRow(message: model.actionErrorMessage)
            if let nodes = model.payload {
                if nodes.isEmpty {
                    Text("This server has no nodes").foregroundStyle(.bloemMuted)
                } else {
                    ForEach(nodes) { node in
                        NodeCard(node: node, model: model, client: client)
                    }
                }
            }
        }
        .navigationTitle("Nodes")
        .sectionLoading(model, client: client)
        .accessibilityIdentifier("nodes-page")
    }
}

/// All servers: one section of nodes per server.
struct AggregateNodesView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver

    var body: some View {
        AggregateSectionsView(
            servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient,
            emptyText: "No nodes", isEmpty: { $0.isEmpty },
            makeModel: {
                AggregateSectionsModel(
                    loadFallback: String(localized: "Could not load nodes."),
                    make: { SectionModel<[NodeSummary]>.nodes(serverName: $0) },
                    fetch: { try await $0.nodeSummaries() }
                )
            }
        ) { _, section, nodes, client in
            ForEach(nodes) { node in
                NodeCard(node: node, model: section, client: client)
            }
        }
        .navigationTitle("Nodes · All servers")
    }
}

private enum NodeAction: Identifiable {
    case drain, resume, enable, disable
    var id: Self { self }
}

/// One node: state first, then load, capacity and the actions it can take.
struct NodeCard: View {
    let node: NodeSummary
    let model: SectionModel<[NodeSummary]>
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @State private var pending: NodeAction?

    var body: some View {
        let row = NodePresentation(node: node, now: Date())
        let busy = model.busyIDs.contains(node.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name).bloemText(.titleMedium)
                Spacer(minLength: 8)
                StatusLabel(row.stateText, tone: row.state.statusTone)
            }
            Text([row.typeText, row.group].compactMap { $0 }.joined(separator: " · "))
                .bloemText(.bodySmall)
                .foregroundStyle(.bloemMuted)
            if let label = row.drainLabel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).bloemText(.bodyMedium)
                    if let detail = row.drainDetail {
                        Text(detail).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                }
            }
            loadBlock(row)
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(row.jobsAtLimit ? "Capacity, at the limit" : "Capacity", value: row.jobs)
                LabeledContent("Egress", value: row.egress)
                Text(row.lastCheck).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            .bloemText(.bodyMedium)
            actions(row, busy: busy)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("node-\(node.id)")
        .confirmationDialog(
            title(for: pending, name: row.name),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(confirmTitle(action), role: action == .resume || action == .enable ? nil : .destructive) {
                Task { await perform(action) }
            }
            Button("Keep as is", role: .cancel) {}
        } message: { action in
            Text(message(for: action))
        }
    }

    @ViewBuilder
    private func loadBlock(_ row: NodePresentation) -> some View {
        if let load = row.load {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("CPU", value: load.cpu)
                LabeledContent("Memory", value: load.memory)
                if let disk = load.disk {
                    LabeledContent(load.diskWarning ? "Disk, nearly full" : "Disk", value: disk)
                }
                LabeledContent("Network", value: load.network)
            }
            .bloemText(.bodyMedium)
        } else if let reason = row.loadUnavailable {
            Text(reason).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
        }
    }

    @ViewBuilder
    private func actions(_ row: NodePresentation, busy: Bool) -> some View {
        VStack(spacing: 8) {
            if busy {
                ProgressView()
            }
            if row.canDrain {
                Button("Drain") { pending = .drain }
                    .accessibilityIdentifier("node-drain-\(node.id)")
            }
            if row.canResume {
                Button("Resume") { pending = .resume }
                    .accessibilityIdentifier("node-resume-\(node.id)")
            }
            Button(row.enableActionTitle) { pending = node.enabled ? .disable : .enable }
                .accessibilityIdentifier("node-enable-\(node.id)")
            Button("Check now") { Task { await model.checkNow(id: node.id, client: client, sessionState: sessionState) } }
                .accessibilityIdentifier("node-check-\(node.id)")
        }
        .buttonStyle(.bloemSecondary)
        .frame(maxWidth: .infinity)
        .disabled(busy)
    }

    private func perform(_ action: NodeAction) async {
        switch action {
        case .drain: await model.drain(id: node.id, client: client, sessionState: sessionState)
        case .resume: await model.resume(id: node.id, client: client, sessionState: sessionState)
        case .enable: await model.setEnabled(true, id: node.id, client: client, sessionState: sessionState)
        case .disable: await model.setEnabled(false, id: node.id, client: client, sessionState: sessionState)
        }
    }

    private func title(for action: NodeAction?, name: String) -> String {
        switch action {
        case .drain: String(localized: "Drain \(name)?")
        case .resume: String(localized: "Resume \(name)?")
        case .enable: String(localized: "Enable \(name)?")
        case .disable: String(localized: "Disable \(name)?")
        case nil: ""
        }
    }

    private func confirmTitle(_ action: NodeAction) -> String {
        switch action {
        case .drain: String(localized: "Drain")
        case .resume: String(localized: "Resume")
        case .enable: String(localized: "Enable")
        case .disable: String(localized: "Disable")
        }
    }

    private func message(for action: NodeAction) -> String {
        switch action {
        case .drain: String(localized: "New work stops going to this node. Sessions already on it keep playing until they end")
        case .resume: String(localized: "The node takes new work again")
        case .enable: String(localized: "The server starts using this node again")
        case .disable: String(localized: "The server stops using this node. Sessions on it may be cut off")
        }
    }
}
