import SwiftUI

/// Preferences: the settings the account's people saved in their apps, by level (a profile's
/// settings for every device, then what a device, app family, library or series replaces for it),
/// like the web's Preferences tab. A level shows only the settings it stores. Scalar settings are
/// edited in place with the contract's own controls; each write addresses one row. Anything the
/// contract types as an object is shown, not edited.
struct UserPreferencesTab: View {
    let user: AdminUser
    let editable: Bool
    @State private var model: UserPreferencesViewModel
    @State private var selectedID: String?

    init(user: AdminUser, admin: UserAdmin, devicesAvailable: Bool, editable: Bool) {
        self.user = user
        self.editable = editable
        _model = State(initialValue: UserPreferencesViewModel(admin: admin, userID: user.id, devicesAvailable: devicesAvailable))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.state {
            case .loading:
                Text("Loading settings…").foregroundStyle(.bloemMuted)
            case .failed(let message):
                Text(message).foregroundStyle(.bloemDanger)
                Button("Try again") { Task { await model.load() } }.frame(minHeight: 44)
            case .ready(let groups, let definitions):
                ready(groups: groups, canEdit: editable && definitions != nil)
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private func ready(groups: [PreferenceLevelGroup], canEdit: Bool) -> some View {
        if !editable {
            Text("You can view this account's settings but not change them").foregroundStyle(.bloemMuted)
        }
        if let message = model.errorMessage {
            VStack(alignment: .leading, spacing: 4) {
                Text(message).foregroundStyle(.bloemDanger)
                Button("Dismiss") { model.dismissError() }.frame(minHeight: 44)
            }
        }
        let levels = groups.flatMap(\.levels)
        if levels.isEmpty {
            Text("This account has no profiles with settings yet").foregroundStyle(.bloemMuted)
        } else {
            let selected = levels.first { $0.id == selectedID }
                ?? levels.first { $0.kind == .profile }
                ?? levels[0]
            LevelPicker(groups: groups, selected: selected) { selectedID = $0.id }
            LevelSettings(model: model, level: selected, levels: levels, canEdit: canEdit)
        }
    }
}

// MARK: - Naming

private enum LevelText {
    static func name(_ level: PreferenceLevel) -> String {
        switch level.kind {
        case .account: String(localized: "Account-wide")
        case .profile: String(localized: "All devices")
        case .device:
            level.deviceName
                ?? ((level.deviceID ?? "").isEmpty
                    ? String(localized: "Unknown device")
                    : String(localized: "Device \(String((level.deviceID ?? "").prefix(8)))"))
        case .client: String(localized: "\(familyName(level.clientFamily ?? "")) apps")
        case .library:
            level.libraryName.map { String(localized: "\($0) library") }
                ?? String(localized: "Library \(level.libraryID ?? "")")
        case .series: String(localized: "Series \(level.seriesID ?? "")")
        }
    }

    static func familyName(_ family: String) -> String {
        family == "tv" ? "TV" : family.prefix(1).uppercased() + family.dropFirst()
    }

    static func title(_ level: PreferenceLevel) -> String {
        level.kind == .account ? name(level) : "\(name(level)) · \(level.profileName)"
    }

    static func description(_ level: PreferenceLevel) -> String {
        let profile = level.profileName
        switch level.kind {
        case .account: return String(localized: "These apply to every profile on the account")
        case .profile: return String(localized: "These apply on every device \(profile) uses")
        case .device: return String(localized: "These replace \(profile)'s settings on this device only; everything else follows \(profile).")
        case .client: return String(localized: "These replace \(profile)'s settings in these apps only; everything else follows \(profile).")
        case .library: return String(localized: "These replace \(profile)'s settings in this library only; everything else follows \(profile).")
        case .series: return String(localized: "These replace \(profile)'s settings for this series only; everything else follows \(profile).")
        }
    }

    static func option(_ name: String, count: Int) -> String {
        String(localized: "\(name) (\(count))")
    }
}

/// Picks the level whose settings are shown. Grouped by profile, with how many settings each level stores.
private struct LevelPicker: View {
    let groups: [PreferenceLevelGroup]
    let selected: PreferenceLevel
    let onSelect: (PreferenceLevel) -> Void

    var body: some View {
        let current = LevelText.option(LevelText.title(selected), count: selected.entries.count)
        Menu {
            ForEach(groups) { group in
                Section(group.profileName.map { String(localized: "Profile · \($0)") } ?? String(localized: "Account")) {
                    ForEach(group.levels) { level in
                        Button {
                            onSelect(level)
                        } label: {
                            if level.id == selected.id {
                                Label(LevelText.option(LevelText.name(level), count: level.entries.count), icon: .check)
                            } else {
                                Text(LevelText.option(LevelText.name(level), count: level.entries.count))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(current).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                IconImage(.chevronsUpDown, size: .inline)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .accessibilityLabel("Setting level: \(current)")
    }
}

// MARK: - A level's settings

private struct LevelSettings: View {
    let model: UserPreferencesViewModel
    let level: PreferenceLevel
    let levels: [PreferenceLevel]
    let canEdit: Bool
    @State private var removing: UserSettingEntry?
    @State private var adding = false

    private var profileEntries: [UserSettingEntry] {
        levels.first { $0.kind == .profile && $0.profileID == level.profileID }?.entries ?? []
    }

    private var addable: [SettingDefinition] {
        PreferenceLevels.addableSettings(level: level, definitions: model.loadedDefinitions ?? [])
    }

    var body: some View {
        DetailCard(LevelText.title(level)) {
            Text(LevelText.description(level)).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            if level.entries.isEmpty {
                Text("Nothing is set here").bloemText(.titleSmall)
                if level.kind == .profile || level.kind == .account {
                    Text("\(level.profileName.isEmpty ? LevelText.name(level) : level.profileName) follows the app defaults")
                        .foregroundStyle(.bloemMuted)
                } else {
                    Text("Everything here follows \(level.profileName)").foregroundStyle(.bloemMuted)
                }
            }
            ForEach(level.entries) { entry in
                let definition = model.definition(for: entry.key)
                SettingRow(
                    entry: entry,
                    definition: definition,
                    replaces: replacesText(PreferenceLevels.replacedValue(level: level, key: entry.key, profileEntries: profileEntries, definition: definition), definition),
                    editable: canEdit,
                    busy: model.isBusy,
                    onSet: { value in Task { _ = await model.set(key: entry.key, identity: entry.identity, value: value) } },
                    onRemove: { removing = entry }
                )
                Divider()
            }
            if canEdit && !addable.isEmpty {
                Button("Add a setting") { adding = true }
                    .buttonStyle(.bloemSecondary)
                    .frame(minHeight: 44)
                    .disabled(model.isBusy)
            }
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { entry in
            Button(removalConfirm(entry), role: .destructive) {
                removing = nil
                Task { _ = await model.remove(entry) }
            }
            .disabled(model.isBusy)
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { entry in
            Text(removalBody(entry))
        }
        .sheet(isPresented: $adding) {
            AddSettingsSheet(settings: addable) { keys in
                adding = false
                // In the contract's order, so the rows land the way the level lists them.
                let ordered = addable.map(\.key).filter(keys.contains)
                Task { _ = await model.add(to: level, keys: ordered) }
            }
        }
    }

    private func fromProfile(_ entry: UserSettingEntry) -> Bool {
        PreferenceLevels.replacedValue(level: level, key: entry.key, profileEntries: profileEntries, definition: model.definition(for: entry.key)).profileName != nil
    }

    private var removalTitle: String {
        guard let entry = removing else { return "" }
        return fromProfile(entry)
            ? String(localized: "Use \(level.profileName)'s value?")
            : String(localized: "Go back to the app default?")
    }

    private func removalBody(_ entry: UserSettingEntry) -> String {
        let label = model.definition(for: entry.key)?.displayLabel ?? entry.key
        return fromProfile(entry)
            ? String(localized: "\(label) goes back to \(level.profileName)'s setting. The change reaches the app the next time it syncs.")
            : String(localized: "\(label) goes back to the app default. The change reaches the app the next time it syncs.")
    }

    private func removalConfirm(_ entry: UserSettingEntry) -> String {
        fromProfile(entry) ? String(localized: "Use \(level.profileName)'s") : String(localized: "Use app default")
    }

    private func replacesText(_ replaced: ReplacedValue, _ definition: SettingDefinition?) -> String {
        let text = PreferenceLevels.valueText(
            definition: definition, value: replaced.value,
            on: String(localized: "On"), off: String(localized: "Off"), unset: String(localized: "Not set")
        )
        if let profileName = replaced.profileName { return String(localized: "Replaces \(profileName): \(text)") }
        if replaced.value == nil { return String(localized: "Replaces the app default") }
        return String(localized: "Replaces app default: \(text)")
    }
}

/// One stored setting: what it is, what it replaces, and the control for its type.
private struct SettingRow: View {
    let entry: UserSettingEntry
    let definition: SettingDefinition?
    let replaces: String
    let editable: Bool
    let busy: Bool
    let onSet: (JSONValue) -> Void
    let onRemove: () -> Void

    private var label: String { definition?.displayLabel ?? entry.key }
    private var editor: ValueEditor { PreferenceLevels.editor(for: definition, current: entry.value) }

    private func shown(_ value: JSONValue?) -> String {
        PreferenceLevels.valueText(
            definition: definition, value: value,
            on: String(localized: "On"), off: String(localized: "Off"), unset: String(localized: "Not set")
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(definition.map { PreferenceLevels.categoryTitle($0.category) } ?? String(localized: "Not in this version"))
                        .bloemText(.labelSmall).foregroundStyle(.bloemMuted)
                    Text(label)
                    Text(replaces).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                Spacer(minLength: 8)
                if editable {
                    Button(role: .destructive, action: onRemove) {
                        IconImage(.trash2, size: .row)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(busy)
                    .accessibilityLabel("Remove \(label)")
                }
            }
            control
        }
    }

    @ViewBuilder
    private var control: some View {
        if !editable || editor == .viewOnly {
            Text(shown(entry.value)).foregroundStyle(.bloemMuted)
            if editor == .viewOnly && editable {
                Text("View only").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
        } else {
            switch editor {
            case .toggle:
                Toggle(label, isOn: Binding(get: { entry.value.boolValue == true }, set: { onSet(.bool($0)) }))
                    .labelsHidden()
                    .disabled(busy)
                    .frame(minHeight: 44)
                    .accessibilityLabel(label)
            case .choice(let options):
                Menu {
                    ForEach(options.indices, id: \.self) { index in
                        let option = options[index]
                        Button(option.label ?? option.value.editText) {
                            if option.value != entry.value { onSet(option.value) }
                        }
                    }
                } label: {
                    Text(shown(entry.value))
                        .frame(minHeight: 44)
                }
                .disabled(busy)
                .accessibilityLabel("\(label): \(shown(entry.value))")
            case .number(let integer, let minimum, let maximum, let nullable):
                TypedValueField(
                    label: label, stored: entry.value.editText, busy: busy,
                    parse: { text in
                        switch PreferenceLevels.parseNumber(text, integer: integer, minimum: minimum, maximum: maximum, nullable: nullable) {
                        case .ok(let value): .valid(value)
                        case .notANumber: .invalid(String(localized: "Enter a whole number"))
                        case .outOfRange(let low, let high):
                            .invalid(String(localized: "Enter a number from \(Self.plain(low)) to \(Self.plain(high))"))
                        }
                    },
                    keyboard: integer ? .numberPad : .decimalPad,
                    onSet: onSet
                )
            case .text(let nullable):
                TypedValueField(
                    label: label, stored: entry.value.editText, busy: busy,
                    parse: { .valid(PreferenceLevels.parseText($0, nullable: nullable)) },
                    keyboard: .default,
                    onSet: onSet
                )
            case .viewOnly:
                EmptyView()
            }
        }
    }

    private static func plain(_ number: Double?) -> String {
        guard let number else { return "…" }
        return number == number.rounded() ? String(Int64(number)) : String(number)
    }
}

/// A number or text field with its own Save: nothing is written until the typed value is valid
/// and different.
private struct TypedValueField: View {
    enum Parsed {
        case valid(JSONValue)
        case invalid(String)
    }

    let label: String
    let stored: String
    let busy: Bool
    let parse: (String) -> Parsed
    let keyboard: UIKeyboardType
    let onSet: (JSONValue) -> Void
    @State private var typed: String

    init(label: String, stored: String, busy: Bool, parse: @escaping (String) -> Parsed, keyboard: UIKeyboardType, onSet: @escaping (JSONValue) -> Void) {
        self.label = label
        self.stored = stored
        self.busy = busy
        self.parse = parse
        self.keyboard = keyboard
        self.onSet = onSet
        _typed = State(initialValue: stored)
    }

    var body: some View {
        let parsed = parse(typed)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(label, text: $typed)
                    .keyboardType(keyboard)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .disabled(busy)
                    .accessibilityLabel(label)
                Button("Save changes") {
                    if case .valid(let value) = parsed { onSet(value) }
                }
                .frame(minHeight: 44)
                .disabled(busy || typed == stored || !isValid(parsed))
            }
            if case .invalid(let message) = parsed {
                Text(message).bloemText(.bodySmall).foregroundStyle(.bloemDanger)
            }
        }
        .onChange(of: stored) { _, new in typed = new }
    }

    private func isValid(_ parsed: Parsed) -> Bool {
        if case .valid = parsed { return true }
        return false
    }
}

/// Picks which settings to add to a level, grouped by category.
private struct AddSettingsSheet: View {
    let settings: [SettingDefinition]
    let onAdd: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked = Set<String>()

    private var categories: [(String, [SettingDefinition])] {
        var order: [String] = []
        var byCategory: [String: [SettingDefinition]] = [:]
        for definition in settings {
            if byCategory[definition.category] == nil { order.append(definition.category) }
            byCategory[definition.category, default: []].append(definition)
        }
        return order.map { ($0, byCategory[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(categories, id: \.0) { entry in
                    Section(PreferenceLevels.categoryTitle(entry.0)) {
                        ForEach(entry.1, id: \.key) { definition in
                            Toggle(definition.displayLabel, isOn: Binding(
                                get: { picked.contains(definition.key) },
                                set: { on in if on { picked.insert(definition.key) } else { picked.remove(definition.key) } }
                            ))
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
            .navigationTitle("Add a setting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { onAdd(picked) }.disabled(picked.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
