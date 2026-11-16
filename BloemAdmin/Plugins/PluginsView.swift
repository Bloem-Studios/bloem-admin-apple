import SwiftUI

/// The Plugins page of one server: installed plugins with a Needs attention filter, and Restart, On/Off
/// and Update after a confirmation. The catalogue and plugin settings stay on the web.
struct PluginsView: View {
    let client: APIClient
    @Environment(ShellRouter.self) private var router: ShellRouter?
    @State private var model = SectionModel<[PluginInstallation]>.plugins()
    @State private var filter = PluginFilter.all
    @State private var query = ""

    var body: some View {
        ScrollViewReader { proxy in
            list
                // A link that names a plugin (a tapped notification) scrolls to it once the page has it.
                .onChange(of: router?.itemFocus, initial: true) { _, _ in scrollToFocusedPlugin(proxy) }
                .onChange(of: model.payload?.map(\.id)) { _, _ in scrollToFocusedPlugin(proxy) }
        }
    }

    /// Scrolls to the plugin a link named. The list starts on All, so a plugin the page has is shown; one it
    /// does not have after it has loaded is dropped.
    private func scrollToFocusedPlugin(_ proxy: ScrollViewProxy) {
        guard let router, let focus = router.itemFocus, focus.pageID == DeepLinkPage.plugins,
              let plugins = model.payload else { return }
        _ = router.takeItemFocus(for: DeepLinkPage.plugins)
        guard plugins.contains(where: { $0.id == focus.itemID }) else { return }
        filter = .all
        query = ""
        withAnimation { proxy.scrollTo(focus.itemID, anchor: .top) }
    }

    private var list: some View {
        List {
            ActionErrorRow(message: model.actionErrorMessage)
            if let plugins = model.payload {
                if plugins.isEmpty {
                    Text("No plugins installed").foregroundStyle(.bloemMuted)
                } else {
                    Section {
                        Picker("Show", selection: $filter) {
                            ForEach(PluginFilter.allCases) { option in
                                Text("\(option.title) (\(option.count(in: plugins)))").tag(option)
                            }
                        }
                        .accessibilityIdentifier("plugins-filter")
                    }
                    let shown = PluginFilter.sorted(PluginFilter.search(query, in: filter.apply(to: plugins)))
                    if shown.isEmpty {
                        Text("No installed plugins match").foregroundStyle(.bloemMuted)
                    }
                    ForEach(shown) { plugin in
                        PluginCard(plugin: plugin, model: model, client: client)
                    }
                    Text("To install plugins or change their settings, use the web admin")
                        .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
            }
        }
        .searchable(text: $query, prompt: "Search installed plugins")
        .navigationTitle("Plugins")
        .sectionLoading(model, client: client)
        .accessibilityIdentifier("plugins-page")
    }
}

/// All servers: one section of plugins per server, problems first.
struct AggregatePluginsView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver

    var body: some View {
        AggregateSectionsView(
            servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient,
            emptyText: "No plugins installed", isEmpty: { $0.isEmpty },
            makeModel: {
                AggregateSectionsModel(
                    loadFallback: String(localized: "Could not load plugins."),
                    make: { SectionModel<[PluginInstallation]>.plugins(serverName: $0) },
                    fetch: { try await $0.pluginInstallations() }
                )
            }
        ) { _, section, plugins, client in
            ForEach(PluginFilter.sorted(plugins)) { plugin in
                PluginCard(plugin: plugin, model: section, client: client)
            }
        }
        .navigationTitle("Plugins · All servers")
    }
}

private enum PluginAction: Identifiable {
    case restart, turnOff, turnOn, update
    var id: Self { self }
}

/// One installed plugin: status first, then what is wrong or available, then the actions it can take.
struct PluginCard: View {
    let plugin: PluginInstallation
    let model: SectionModel<[PluginInstallation]>
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @State private var pending: PluginAction?

    var body: some View {
        let row = PluginPresentation(plugin)
        let busy = model.busyIDs.contains(plugin.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name).bloemText(.titleMedium)
                Spacer(minLength: 8)
                StatusLabel(row.statusText, tone: row.statusTone)
            }
            Text("Version \(row.version)").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            if let detail = row.detail {
                Label(detail, icon: row.needsAttention ? .triangleAlert : .info)
                    .bloemText(.bodySmall)
            }
            if let update = row.updateText {
                Text(update).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            VStack(spacing: 8) {
                if busy { ProgressView() }
                if row.canRestart {
                    Button("Restart") { pending = .restart }
                        .accessibilityIdentifier("plugin-restart-\(plugin.id)")
                }
                Button(row.toggleActionTitle) { pending = row.isEnabled ? .turnOff : .turnOn }
                    .accessibilityIdentifier("plugin-toggle-\(plugin.id)")
                if let version = row.pendingUpdate {
                    Button("Update to \(version)") { pending = .update }
                        .accessibilityIdentifier("plugin-update-\(plugin.id)")
                }
            }
            .buttonStyle(.bloemSecondary)
            .frame(maxWidth: .infinity)
            .disabled(busy)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-\(plugin.id)")
        .confirmationDialog(
            title(pending, row: row),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(confirmTitle(action), role: action == .turnOff ? .destructive : nil) {
                Task { await perform(action) }
            }
            Button("Keep as is", role: .cancel) {}
        } message: { action in
            Text(message(action, row: row))
        }
    }

    private func perform(_ action: PluginAction) async {
        switch action {
        case .restart: await model.restart(id: plugin.id, client: client, sessionState: sessionState)
        case .turnOff: await model.setEnabled(false, id: plugin.id, client: client, sessionState: sessionState)
        case .turnOn: await model.setEnabled(true, id: plugin.id, client: client, sessionState: sessionState)
        case .update: await model.applyUpdate(id: plugin.id, client: client, sessionState: sessionState)
        }
    }

    private func title(_ action: PluginAction?, row: PluginPresentation) -> String {
        switch action {
        case .restart: String(localized: "Restart \(row.name)?")
        case .turnOff: String(localized: "Turn off \(row.name)?")
        case .turnOn: String(localized: "Turn on \(row.name)?")
        case .update: String(localized: "Update \(row.name) to \(row.pendingUpdate ?? "")?")
        case nil: ""
        }
    }

    private func confirmTitle(_ action: PluginAction) -> String {
        switch action {
        case .restart: String(localized: "Restart")
        case .turnOff: String(localized: "Turn off")
        case .turnOn: String(localized: "Turn on")
        case .update: String(localized: "Update")
        }
    }

    private func message(_ action: PluginAction, row: PluginPresentation) -> String {
        switch action {
        case .restart: String(localized: "The plugin's process restarts. Requests to it fail for a moment")
        case .turnOff: String(localized: "Anything that depends on this plugin stops working until you turn it on again")
        case .turnOn: String(localized: "The server starts using this plugin again")
        case .update: String(localized: "The plugin restarts on the new version. If the update fails, it stays on version \(row.version)")
        }
    }
}
