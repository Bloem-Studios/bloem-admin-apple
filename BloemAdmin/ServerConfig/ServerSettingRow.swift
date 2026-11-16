import SwiftUI

/// One catalogue setting as a labelled, typed control: a switch, a number with its unit, a choice, text
/// or a secret that only says whether it is set. Under the control: the web's help text, whether the
/// change waits for a restart, whether the server's environment owns the value, and what the server now
/// holds when someone else changed it.
struct ServerSettingRow: View {
    let spec: SettingSpec
    let model: ServerSettingsModel

    private var managed: Bool { model.isManagedByEnvironment(spec.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            control
                .disabled(managed)
            if let help = spec.helpText {
                Text(help)
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            notes
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setting.\(spec.key)")
    }

    @ViewBuilder
    private var control: some View {
        switch spec.control {
        case .toggle:
            Toggle(isOn: toggleBinding) { SettingLabel(text: spec.labelText, isEdited: model.isDirty(spec.key)) }
                .accessibilityIdentifier("setting.\(spec.key).toggle")
        case .number(let unit, _, _, _):
            NumberSettingField(spec: spec, unit: unit.map { String(localized: $0) }, model: model)
        case .choice(let choices):
            ChoiceSettingField(spec: spec, choices: choices, model: model)
        case .text(let placeholder, let kind):
            TextSettingField(spec: spec, placeholder: placeholder, kind: kind, model: model)
        case .secret:
            SecretSettingField(spec: spec, model: model)
        }
    }

    @ViewBuilder
    private var notes: some View {
        if managed {
            Label("Set by the server's environment. Change it there", icon: .lock)
                .bloemText(.bodySmall)
                .foregroundStyle(.bloemMuted)
        }
        if model.requiresRestart(spec.key) {
            Label("Applies after a restart", icon: .rotateCw)
                .bloemText(.bodySmall)
                .foregroundStyle(.bloemMuted)
                .accessibilityIdentifier("setting.\(spec.key).restart")
        }
        if let serverValue = model.serverValue(for: spec.key) {
            Label(String(localized: "The server now has \(display(serverValue))"), icon: .triangleAlert)
                .bloemText(.bodySmall)
                .foregroundStyle(.primary)
        }
    }

    private func display(_ raw: String) -> String {
        if case .choice(let choices) = spec.control, let match = choices.first(where: { $0.value == raw }) {
            return String(localized: match.label)
        }
        if case .toggle = spec.control {
            return raw == "true" ? String(localized: "on") : String(localized: "off")
        }
        let shown = spec.control.displayValue(raw)
        return shown.isEmpty ? String(localized: "no value") : shown
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { model.value(for: spec.key) == "true" },
            set: { model.setDraft($0 ? "true" : "false", for: spec.key) }
        )
    }
}

/// A setting's name, with a small mark while it has an unsaved edit.
struct SettingLabel: View {
    let text: String
    let isEdited: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isEdited {
                Circle()
                    .fill(Theme.text)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(String(localized: "Unsaved change"))
            }
            Text(text)
        }
    }
}

private struct NumberSettingField: View {
    let spec: SettingSpec
    let unit: String?
    let model: ServerSettingsModel
    @State private var text = ""
    @State private var didStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 8) {
                    TextField(String(localized: "Value"), text: $text)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 60)
                        .accessibilityLabel(spec.labelText)
                        .accessibilityIdentifier("setting.\(spec.key).field")
                    if let unit {
                        Text(unit).foregroundStyle(.bloemMuted)
                    }
                }
            } label: {
                SettingLabel(text: spec.labelText, isEdited: model.isDirty(spec.key))
            }
            if let problem = spec.control.problem(with: model.value(for: spec.key)) {
                Label(problem, icon: .triangleAlert)
                    .bloemText(.bodySmall)
                    .foregroundStyle(.primary)
            } else if invalidText {
                Label("Use a whole number", icon: .triangleAlert)
                    .bloemText(.bodySmall)
                    .foregroundStyle(.primary)
            }
        }
        .onAppear {
            guard !didStart else { return }
            didStart = true
            text = spec.control.displayValue(model.value(for: spec.key))
        }
        .onChange(of: text) { _, newText in
            guard let stored = spec.control.storedValue(fromDisplay: newText) else { return }
            if stored != model.value(for: spec.key) { model.setDraft(stored, for: spec.key) }
        }
        .onChange(of: model.value(for: spec.key)) { _, newValue in
            // Something else changed the value (Discard, a save, a refresh): show it.
            let shown = spec.control.displayValue(newValue)
            if spec.control.storedValue(fromDisplay: text) != newValue { text = shown }
        }
    }

    private var invalidText: Bool {
        spec.control.storedValue(fromDisplay: text) == nil
    }
}

private struct ChoiceSettingField: View {
    let spec: SettingSpec
    let choices: [SettingChoice]
    let model: ServerSettingsModel

    var body: some View {
        let current = model.value(for: spec.key)
        Picker(selection: Binding(
            get: { current },
            set: { model.setDraft($0, for: spec.key) }
        )) {
            ForEach(choices, id: \.value) { choice in
                Text(choice.label).tag(choice.value)
            }
            // A value this app does not know stays selectable as it is, so showing it never changes it.
            if !choices.contains(where: { $0.value == current }) {
                Text(current.isEmpty ? String(localized: "Not set") : current).tag(current)
            }
        } label: {
            SettingLabel(text: spec.labelText, isEdited: model.isDirty(spec.key))
        }
        .accessibilityIdentifier("setting.\(spec.key).picker")
    }
}

private struct TextSettingField: View {
    let spec: SettingSpec
    let placeholder: String?
    let kind: SettingTextKind
    let model: ServerSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingLabel(text: spec.labelText, isEdited: model.isDirty(spec.key))
                .bloemText(.bodyMedium)
            TextField(
                placeholder ?? String(localized: "Not set"),
                text: Binding(
                    get: { model.value(for: spec.key) },
                    set: { model.setDraft($0, for: spec.key) }
                )
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .accessibilityLabel(spec.labelText)
            .accessibilityIdentifier("setting.\(spec.key).field")
        }
    }

    private var keyboard: UIKeyboardType {
        switch kind {
        case .plain: .default
        case .url: .URL
        case .email: .emailAddress
        }
    }
}

/// A secret is never shown. The row says whether one is set, takes a new value, and can clear it.
private struct SecretSettingField: View {
    let spec: SettingSpec
    let model: ServerSettingsModel

    private var stagedClear: Bool { model.drafts[spec.key] == "" }
    private var typed: String { model.drafts[spec.key] ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(statusText)
                    .foregroundStyle(.bloemMuted)
                    .accessibilityIdentifier("setting.\(spec.key).status")
            } label: {
                SettingLabel(text: spec.labelText, isEdited: model.isDirty(spec.key))
            }
            if stagedClear {
                HStack {
                    Text("Will be cleared when you save")
                        .bloemText(.bodySmall)
                        .foregroundStyle(.bloemMuted)
                    Spacer()
                    Button("Keep it") { model.discard(keys: [spec.key]) }
                        .bloemText(.bodySmall)
                }
            } else {
                SecureField(
                    model.isSecretSet(spec.key) ? String(localized: "New value") : String(localized: "Value"),
                    text: Binding(
                        get: { typed },
                        set: { newValue in
                            if newValue.isEmpty { model.discard(keys: [spec.key]) } else { model.setDraft(newValue, for: spec.key, secret: true) }
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(spec.labelText)
                .accessibilityIdentifier("setting.\(spec.key).field")
                if model.isSecretSet(spec.key), typed.isEmpty {
                    Button("Clear", role: .destructive) { model.setDraft("", for: spec.key, secret: true) }
                        .bloemText(.bodySmall)
                        .accessibilityIdentifier("setting.\(spec.key).clear")
                }
            }
            if model.sensitiveUnavailable {
                Text("Could not read whether this is set. You can still enter a new value")
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
            }
        }
    }

    private var statusText: String {
        if model.sensitiveUnavailable, model.drafts[spec.key] == nil { return String(localized: "Unknown") }
        return model.isSecretSet(spec.key) ? String(localized: "Set") : String(localized: "Not set")
    }
}
