import SwiftUI

/// The API keys page (Configure, Access): every key on the server with its owner, what it may do and when it was
/// last used, and Revoke with a confirmation. Keys are created, and their rate tier changed, on the web.
struct APIKeysListView: View {
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @State private var model: APIKeysViewModel
    @State private var pendingRevoke: AdminAPIKey?
    @State private var revoked = false

    init(client: APIClient) {
        self.client = client
        _model = State(initialValue: APIKeysViewModel(client: client))
    }

    var body: some View {
        List {
            if model.notice != nil || model.errorMessage != nil {
                Section {
                    if let message = model.errorMessage {
                        Label(message, icon: .triangleAlert)
                            .bloemText(.bodyLarge)
                            .accessibilityIdentifier("api-keys-error")
                    }
                    if let notice = model.notice {
                        Text(notice).bloemText(.bodyLarge).accessibilityIdentifier("api-keys-notice")
                    }
                    Button("Dismiss") { model.dismissMessages() }.buttonStyle(.bloemQuiet).frame(minHeight: 44)
                }
            }
            Section {
                content
            } footer: {
                if model.keys?.isEmpty == false {
                    Text("Create keys, and change a key's rate tier, on the web admin.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("API keys")
        .task {
            model.sessionState = sessionState
            await model.load()
        }
        .refreshable { await model.load() }
        .sensoryFeedback(.success, trigger: revoked)
        // An alert, not a confirmation dialog: on iOS 26 a dialog shows as a popover with no Cancel button.
        .alert(
            pendingRevoke.map { APIKeyText.revokeTitle($0.displayLabel) } ?? "",
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            presenting: pendingRevoke
        ) { key in
            Button("Revoke key", role: .destructive) {
                Task { if await model.revoke(key) { revoked.toggle() } }
            }
            Button("Keep key", role: .cancel) {}
        } message: { key in
            Text(APIKeyText.revokeMessage(key.displayLabel))
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24)
        } else if model.isUnavailable {
            BloemEmptyState {
                Label("API key administration isn't available on this server", icon: .keyRound)
            } description: {
                Text("The server has no API key service running. Check its configuration on the web, then pull down to check again.")
            }
            .accessibilityIdentifier("api-keys-unavailable")
        } else if let failure = model.loadFailure, model.keys == nil {
            LoadFailureView(failure: failure) { Task { await model.load() } }
        } else if let keys = model.keys, keys.isEmpty {
            BloemEmptyState(
                "No API keys yet", icon: .keyRound,
                description: Text("Keys are created on the web admin and listed here.")
            )
        } else if let keys = model.keys {
            ForEach(keys) { key in
                row(key)
            }
            if model.moreFailed {
                Text("More keys could not be loaded").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            if model.hasMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    HStack {
                        Spacer()
                        if model.isLoadingMore { ProgressView() } else { Text("Load more") }
                        Spacer()
                    }
                    .frame(minHeight: 44)
                }
                .disabled(model.isLoadingMore)
                .accessibilityIdentifier("api-keys-load-more")
            }
        }
    }

    private func row(_ key: AdminAPIKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(key.displayLabel).bloemText(.titleMedium)
            VStack(alignment: .leading, spacing: 4) {
                Text(APIKeyText.owner(key.username))
                Text(APIKeyText.scopes(key.scopes))
                Text(APIKeyText.lastUsed(key.lastUsedAt))
                if let tier = APIKeyText.rateTier(key.rateTier) { Text(tier) }
                if !key.keyPrefix.isEmpty {
                    Text(key.keyPrefix).bloemText(.bodySmall)
                }
            }
            .bloemText(.bodyMedium)
            .foregroundStyle(.bloemMuted)
            HStack {
                Button(role: .destructive) {
                    pendingRevoke = key
                } label: {
                    Text("Revoke").frame(minHeight: 44)
                }
                .buttonStyle(.bloemSecondary)
                .disabled(model.isBusy(key))
                .accessibilityLabel("Revoke \(key.displayLabel)")
                .accessibilityIdentifier("api-key-revoke-\(key.id)")
                if model.isBusy(key) { ProgressView() }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("api-key-row-\(key.id)")
    }
}
