import Foundation

enum LevelKind: Equatable, Sendable {
    case account, profile, device, client, library, series

    var scope: String {
        switch self {
        case .account: "account"
        case .profile: "profile"
        case .device: "profile_device"
        case .client: "profile_client"
        case .library: "profile_library"
        case .series: "profile_series"
        }
    }

    /// A level below the profile replaces the profile's own stored value when there is one.
    var replacesProfileValue: Bool {
        switch self {
        case .device, .client, .library, .series: true
        case .account, .profile: false
        }
    }
}

/// One place a setting can be stored for an account, in the order the server resolves them. Each
/// level is exactly one storage identity, so every edit, add or removal on it addresses one row.
struct PreferenceLevel: Identifiable, Equatable, Sendable {
    let id: String
    let kind: LevelKind
    let identity: SettingIdentity
    let profileID: String?
    let profileName: String
    /// Settings stored at exactly this identity, in the contract's order.
    let entries: [UserSettingEntry]
    var deviceID: String?
    /// Nil for a device the account's device list does not know.
    var deviceName: String?
    var clientFamily: String?
    var libraryID: String?
    /// Nil for a library the server's list does not know.
    var libraryName: String?
    var seriesID: String?
}

/// The account level, or one profile with its device, app family, library and series levels.
struct PreferenceLevelGroup: Identifiable, Equatable, Sendable {
    let key: String
    let profileName: String?
    let levels: [PreferenceLevel]

    var id: String { key }
}

/// What a setting on a level replaces. A device, app-family, library or series level replaces the
/// profile's own stored value when there is one; every other case replaces the app default.
/// `profileName` is set only for the first case.
struct ReplacedValue: Equatable, Sendable {
    let profileName: String?
    let value: JSONValue?
}

/// How a stored value is edited in place. Anything else is shown but not edited here.
enum ValueEditor: Equatable, Sendable {
    case toggle
    case choice([SettingOptionDefinition])
    case number(integer: Bool, minimum: Double?, maximum: Double?, nullable: Bool)
    case text(nullable: Bool)
    case viewOnly
}

/// The outcome of reading what the admin typed into a number field.
enum ParsedValue: Equatable, Sendable {
    case ok(JSONValue)
    case notANumber
    case outOfRange(minimum: Double?, maximum: Double?)
}

enum PreferenceLevels {
    static func profileLevelID(_ profileID: String) -> String { "profile.\(profileID)" }

    private static let familyOrder = ["tv", "mobile", "tablet", "desktop", "web"]

    /// Folds the stored settings into levels: the account-wide level when any row has that scope,
    /// then one group per profile in the account's order (a profile no longer listed but still
    /// holding rows follows). Under each profile: All devices, each device the profile has settings
    /// on or was seen with, its app families, libraries and series. `order` ranks keys as the
    /// contract lists them.
    static func build(
        entries: [UserSettingEntry],
        profiles: [UserProfile],
        devices: [UserDevice],
        libraryNames: [String: String],
        order: [String: Int] = [:]
    ) -> [PreferenceLevelGroup] {
        func ranked(_ rows: [UserSettingEntry]) -> [UserSettingEntry] {
            rows.sorted { lhs, rhs in
                let l = order[lhs.key] ?? Int.max
                let r = order[rhs.key] ?? Int.max
                return l != r ? l < r : lhs.key < rhs.key
            }
        }
        let account = ranked(entries.filter { $0.scope == "account" })
        let perProfile = Dictionary(grouping: entries.filter { $0.scope != "account" }) { $0.profileID ?? "" }

        var groups: [PreferenceLevelGroup] = []
        if !account.isEmpty {
            groups.append(PreferenceLevelGroup(
                key: "account", profileName: nil,
                levels: [PreferenceLevel(
                    id: "account", kind: .account, identity: SettingIdentity(scope: "account"),
                    profileID: nil, profileName: "", entries: account
                )]
            ))
        }

        let listed = Set(profiles.map(\.id))
        let orphans = perProfile.keys.filter { !listed.contains($0) }.sorted()
        let ordered = profiles.map { ($0.id, $0.name) } + orphans.map { ($0, $0) }

        for (profileID, profileName) in ordered {
            let rows = perProfile[profileID] ?? []
            func at(_ scope: String) -> [UserSettingEntry] { rows.filter { $0.scope == scope } }
            var levels: [PreferenceLevel] = [PreferenceLevel(
                id: profileLevelID(profileID), kind: .profile, identity: SettingIdentity(scope: "profile", profileID: profileID),
                profileID: profileID, profileName: profileName, entries: ranked(at("profile"))
            )]

            let deviceRows = Dictionary(grouping: at("profile_device")) { $0.deviceID ?? "" }
            func deviceLevel(_ deviceID: String, _ name: String?) -> PreferenceLevel {
                var level = PreferenceLevel(
                    id: "device.\(profileID).\(deviceID)", kind: .device,
                    identity: SettingIdentity(scope: "profile_device", profileID: profileID, deviceID: deviceID),
                    profileID: profileID, profileName: profileName, entries: ranked(deviceRows[deviceID] ?? [])
                )
                level.deviceID = deviceID
                level.deviceName = name
                return level
            }
            var registered = Set<String>()
            for device in devices {
                let seen = device.profiles.contains { $0.profileId == profileID }
                if !seen && deviceRows[device.deviceId] == nil { continue }
                registered.insert(device.deviceId)
                levels.append(deviceLevel(device.deviceId, device.deviceName.isEmpty ? nil : device.deviceName))
            }
            for deviceID in deviceRows.keys.sorted() where !registered.contains(deviceID) {
                levels.append(deviceLevel(deviceID, nil))
            }

            let clientRows = Dictionary(grouping: at("profile_client").filter { $0.clientFamily != nil }) { $0.clientFamily ?? "" }
            let extraFamilies = clientRows.keys.filter { !familyOrder.contains($0) }.sorted()
            for family in familyOrder + extraFamilies {
                guard let familyRows = clientRows[family] else { continue }
                var level = PreferenceLevel(
                    id: "client.\(profileID).\(family)", kind: .client,
                    identity: SettingIdentity(scope: "profile_client", profileID: profileID, clientFamily: family),
                    profileID: profileID, profileName: profileName, entries: ranked(familyRows)
                )
                level.clientFamily = family
                levels.append(level)
            }

            let libraryRows = Dictionary(grouping: at("profile_library").filter { $0.libraryID != nil }) { $0.libraryID ?? "" }
            func libraryLabel(_ id: String) -> String { libraryNames[id] ?? id }
            let libraryIDs = libraryRows.keys.sorted { lhs, rhs in
                let l = libraryLabel(lhs).lowercased()
                let r = libraryLabel(rhs).lowercased()
                return l != r ? l < r : lhs < rhs
            }
            for libraryID in libraryIDs {
                var level = PreferenceLevel(
                    id: "library.\(profileID).\(libraryID)", kind: .library,
                    identity: SettingIdentity(scope: "profile_library", profileID: profileID, libraryID: libraryID),
                    profileID: profileID, profileName: profileName, entries: ranked(libraryRows[libraryID] ?? [])
                )
                level.libraryID = libraryID
                level.libraryName = libraryNames[libraryID]
                levels.append(level)
            }

            let seriesRows = Dictionary(grouping: at("profile_series").filter { $0.seriesID != nil }) { $0.seriesID ?? "" }
            for seriesID in seriesRows.keys.sorted() {
                var level = PreferenceLevel(
                    id: "series.\(profileID).\(seriesID)", kind: .series,
                    identity: SettingIdentity(scope: "profile_series", profileID: profileID, seriesID: seriesID),
                    profileID: profileID, profileName: profileName, entries: ranked(seriesRows[seriesID] ?? [])
                )
                level.seriesID = seriesID
                levels.append(level)
            }
            groups.append(PreferenceLevelGroup(key: "profile.\(profileID)", profileName: profileName, levels: levels))
        }
        return groups
    }

    static func replacedValue(level: PreferenceLevel, key: String, profileEntries: [UserSettingEntry], definition: SettingDefinition?) -> ReplacedValue {
        if level.kind.replacesProfileValue, let stored = profileEntries.first(where: { $0.key == key }) {
            return ReplacedValue(profileName: level.profileName, value: stored.value)
        }
        return ReplacedValue(profileName: nil, value: definition?.defaultValue)
    }

    /// Settings a level can hold that are not set on it yet: stored on the server, not deprecated,
    /// for this level's scope.
    static func addableSettings(level: PreferenceLevel, definitions: [SettingDefinition]) -> [SettingDefinition] {
        let stored = Set(level.entries.map(\.key))
        return definitions.filter {
            $0.persistence == "remote" && !$0.deprecated && $0.allowedScopes.contains(level.kind.scope) && !stored.contains($0.key)
        }
    }

    static func editor(for definition: SettingDefinition?, current: JSONValue? = nil) -> ValueEditor {
        guard let schema = definition?.valueSchema else { return .viewOnly }
        switch schema.type {
        case "boolean": return .toggle
        case "enum": return .choice(schema.values.filter { !$0.deprecated || $0.value == current })
        case "integer": return .number(integer: true, minimum: schema.minimum, maximum: schema.maximum, nullable: schema.nullable)
        case "number": return .number(integer: false, minimum: schema.minimum, maximum: schema.maximum, nullable: schema.nullable)
        case "string", "language_tag": return .text(nullable: schema.nullable)
        default: return .viewOnly
        }
    }

    static func parseNumber(_ text: String, integer: Bool, minimum: Double?, maximum: Double?, nullable: Bool) -> ParsedValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nullable ? .ok(.null) : .notANumber }
        let number: Double
        if integer {
            guard let whole = Int64(trimmed) else { return .notANumber }
            number = Double(whole)
        } else {
            guard let value = Double(trimmed), value.isFinite else { return .notANumber }
            number = value
        }
        if let minimum, number < minimum { return .outOfRange(minimum: minimum, maximum: maximum) }
        if let maximum, number > maximum { return .outOfRange(minimum: minimum, maximum: maximum) }
        if integer, let whole = Int64(trimmed) { return .ok(.integer(whole)) }
        return .ok(.number(number))
    }

    static func parseText(_ text: String, nullable: Bool) -> JSONValue {
        text.isEmpty && nullable ? .null : .string(text)
    }

    /// A value for reading: the option's label for an enum, `on` or `off` for a boolean, `unset`
    /// for null, else its content.
    static func valueText(definition: SettingDefinition?, value: JSONValue?, on: String, off: String, unset: String) -> String {
        guard let value, !value.isNull else { return unset }
        if let flag = value.boolValue { return flag ? on : off }
        if let label = definition?.valueSchema.values.first(where: { $0.value == value })?.label { return label }
        return value.editText
    }

    /// "Playback", "Watch party": a category's title, from its id.
    static func categoryTitle(_ category: String) -> String {
        category.split(whereSeparator: { $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// The value a new setting starts with: what it replaces, so nothing changes until it is edited.
    /// When that is unknown (no default in the contract), a value the setting's type accepts.
    static func startingValue(replaced: ReplacedValue, definition: SettingDefinition) -> JSONValue {
        if let value = replaced.value, !value.isNull { return value }
        let schema = definition.valueSchema
        if schema.nullable { return .null }
        switch schema.type {
        case "boolean": return .bool(false)
        case "enum": return schema.values.first { !$0.deprecated }?.value ?? .null
        case "integer": return .integer(Int64(schema.minimum ?? 0))
        case "number": return .number(schema.minimum ?? 0)
        case "string", "language_tag": return .string("")
        default: return .null
        }
    }
}
