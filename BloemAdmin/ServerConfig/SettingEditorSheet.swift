import SwiftUI

/// Edit form for one setting, driven by `SettingEditor`. It reads the settings snapshot when it opens;
/// a save that loses a race keeps the draft and offers the current value.
struct SettingEditorSheet: View {
    @State private var editor: SettingEditor
    let client: APIClient
    let sessionState: ServerScopedSession?
    let onSaved: (SettingReceipt) -> Void
    @Environment(\.dismiss) private var dismiss

    init(key: String, serverName: String? = nil, client: APIClient, sessionState: ServerScopedSession?, onSaved: @escaping (SettingReceipt) -> Void) {
        _editor = State(initialValue: SettingEditor(key: key, serverName: serverName))
        self.client = client
        self.sessionState = sessionState
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                if editor.snapshot != nil {
                    Section {
                        TextField("Value", text: $editor.draft)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } footer: {
                        Text("Some settings only take effect after the server restarts")
                    }
                }
                if editor.hasConflict {
                    Section {
                        Text(editor.conflictMessage)
                            .foregroundStyle(.bloemDanger)
                        if let latest = editor.latest {
                            LabeledContent(editor.serverName.map { "\($0) current value" } ?? "Current value", value: latest.value)
                            Button("Use current value") { editor.useCurrent() }
                            Button("Keep my edit and continue") { editor.adoptCurrent() }
                        } else {
                            Button("Review current value") {
                                Task { await editor.reviewCurrent(client: client, sessionState: sessionState) }
                            }
                            .disabled(editor.isBusy)
                        }
                    }
                }
                if let message = editor.errorMessage {
                    Section { Text(message).foregroundStyle(.bloemDanger) }
                    if editor.snapshot == nil, !editor.isBusy {
                        Section {
                            Button("Try again") { Task { await editor.open(client: client, sessionState: sessionState) } }
                        }
                    }
                }
            }
            .overlay {
                if editor.isBusy && editor.snapshot == nil { ProgressView() }
            }
            .navigationTitle(editor.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes") {
                        Task {
                            if await editor.save(client: client, sessionState: sessionState), let receipt = editor.receipt {
                                onSaved(receipt)
                                dismiss()
                            }
                        }
                    }
                    .disabled(!editor.canSave)
                }
            }
        }
        .task { await editor.open(client: client, sessionState: sessionState) }
        .interactiveDismissDisabled(editor.isBusy)
    }
}
