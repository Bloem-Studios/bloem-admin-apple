import Foundation

struct PluginRuntime: Decodable, Equatable, Sendable {
    /// `stopped`, `starting`, `running`, `backoff` or `failed`.
    let state: String
    /// The server keeps a resident plugin running; any other starts on first use.
    let resident: Bool
    let restartCount: Int
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case state, resident
        case restartCount = "restart_count"
        case lastError = "last_error"
    }
}

struct PluginUpdateFailure: Decodable, Equatable, Sendable {
    let reason: String
    let version: String
}

struct PluginConfigField: Decodable, Equatable, Sendable {
    let key: String
    let title: String
    let required: Bool
}

struct PluginSavedConfig: Decodable, Equatable, Sendable {
    let key: String
    let value: [String: JSONValue]
    let configuredSecrets: [JSONValue]

    enum CodingKeys: String, CodingKey {
        case key, value
        case configuredSecrets = "configured_secrets"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        value = try container.decodeIfPresent([String: JSONValue].self, forKey: .value) ?? [:]
        configuredSecrets = try container.decodeIfPresent([JSONValue].self, forKey: .configuredSecrets) ?? []
    }
}

/// One installed plugin of `GET /api/v2/admin/plugins/installations`. Only what the page shows and
/// what the web's Needs attention rule reads is decoded; the catalogue and plugin settings stay on the web.
struct PluginInstallation: Decodable, Identifiable, Equatable, Sendable {
    struct Presentation: Decodable, Equatable, Sendable {
        let displayName: String
        let summary: String?
        let publisherName: String?

        enum CodingKeys: String, CodingKey {
            case summary
            case displayName = "display_name"
            case publisherName = "publisher_name"
        }
    }

    struct Signature: Decodable, Equatable, Sendable {
        /// `unknown`, `verified`, `unsigned` or `invalid`.
        let state: String
    }

    let id: String
    let pluginId: String
    let enabled: Bool
    let version: String
    let availableVersion: String?
    /// Absent for a plugin installed from no repository (an upload): such a plugin is not offered updates.
    let repositoryId: String?
    let updatesPaused: Bool
    let updateFailure: PluginUpdateFailure?
    let runtime: PluginRuntime
    let signature: Signature
    let presentation: Presentation?
    let globalConfigSchema: [PluginConfigField]
    let globalConfigs: [PluginSavedConfig]

    enum CodingKeys: String, CodingKey {
        case id, enabled, version, runtime, signature, presentation
        case pluginId = "plugin_id"
        case availableVersion = "available_version"
        case repositoryId = "repository_id"
        case updatesPaused = "updates_paused"
        case updateFailure = "update_failure"
        case globalConfigSchema = "global_config_schema"
        case globalConfigs = "global_configs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        pluginId = try container.decode(String.self, forKey: .pluginId)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        version = try container.decode(String.self, forKey: .version)
        availableVersion = try container.decodeIfPresent(String.self, forKey: .availableVersion)
        repositoryId = try container.decodeIfPresent(String.self, forKey: .repositoryId)
        updatesPaused = try container.decodeIfPresent(Bool.self, forKey: .updatesPaused) ?? false
        updateFailure = try container.decodeIfPresent(PluginUpdateFailure.self, forKey: .updateFailure)
        runtime = try container.decode(PluginRuntime.self, forKey: .runtime)
        signature = try container.decode(Signature.self, forKey: .signature)
        presentation = try container.decodeIfPresent(Presentation.self, forKey: .presentation)
        globalConfigSchema = try container.decodeIfPresent([PluginConfigField].self, forKey: .globalConfigSchema) ?? []
        globalConfigs = try container.decodeIfPresent([PluginSavedConfig].self, forKey: .globalConfigs) ?? []
    }
}

/// What the Plugins page says about one installed plugin, following the web's rules
/// (`pluginStatus.ts`, `pluginConfigReady.ts`): a plugin that is off never needs attention; otherwise a
/// failed runtime, a resident plugin in back-off, missing required settings, a refused update or an invalid
/// signature does.
struct PluginPresentation: Equatable, Identifiable {
    let id: String
    let name: String
    let version: String
    let statusText: String
    /// Why, in a line: the runtime's error, the missing settings, a bad signature.
    let detail: String?
    let needsAttention: Bool
    /// Problems first (most severe first), healthy plugins next, plugins that are off last.
    let rank: Int
    /// The newer version that can be installed now; nil without a repository or while updates are paused.
    let pendingUpdate: String?
    let updateText: String?
    let canRestart: Bool
    let isEnabled: Bool
    let toggleActionTitle: String
    let searchText: String

    init(_ plugin: PluginInstallation) {
        id = plugin.id
        name = Self.displayName(plugin)
        version = plugin.version
        isEnabled = plugin.enabled
        toggleActionTitle = plugin.enabled ? String(localized: "Turn off") : String(localized: "Turn on")
        let runtime = plugin.runtime
        canRestart = runtime.resident && plugin.enabled && runtime.state != "starting"

        let pending = plugin.repositoryId == nil || plugin.updatesPaused ? nil : plugin.availableVersion.flatMap { $0.isEmpty ? nil : $0 }
        pendingUpdate = pending
        if let failure = plugin.updateFailure {
            updateText = String(localized: "Update to \(failure.version) failed: \(failure.reason)")
        } else if let pending {
            updateText = String(localized: "Update to \(pending) available")
        } else if plugin.updatesPaused {
            updateText = String(localized: "Updates paused")
        } else {
            updateText = nil
        }

        let missing = plugin.globalConfigSchema.filter { $0.required && !Self.isSaved($0.key, in: plugin) }
        let indicator = Self.indicator(plugin)
        if !plugin.enabled {
            statusText = indicator
            detail = nil
            needsAttention = false
            rank = 4
        } else if runtime.state == "failed" {
            statusText = indicator
            detail = runtime.lastError.flatMap { $0.isEmpty ? nil : $0 }
            needsAttention = true
            rank = 0
        } else if runtime.resident && runtime.state == "backoff" {
            statusText = indicator
            detail = runtime.lastError.flatMap { $0.isEmpty ? nil : $0 }
            needsAttention = true
            rank = 1
        } else if !missing.isEmpty {
            statusText = String(localized: "Needs setup")
            detail = String(localized: "Missing: \(missing.map { $0.title.isEmpty ? $0.key : $0.title }.joined(separator: ", "))")
            needsAttention = true
            rank = 2
        } else if plugin.updateFailure != nil || plugin.signature.state == "invalid" {
            statusText = indicator
            detail = plugin.signature.state == "invalid" ? String(localized: "The release signature did not check out") : nil
            needsAttention = true
            rank = 2
        } else {
            statusText = indicator
            detail = nil
            needsAttention = false
            rank = 3
        }

        searchText = [name, plugin.pluginId, plugin.presentation?.summary, plugin.presentation?.publisherName]
            .compactMap { $0 }.joined(separator: "\n").lowercased()
    }

    /// How the status word is said: a failed plugin in the failure colour with a dot, one that needs a look in the warning
    /// colour with a dot, everything else quietly (the same rule every page's status follows).
    var statusTone: StatusLabel.Tone {
        switch rank {
        case 0: .failure
        case 1, 2: .warning
        case 3: .positive
        default: .normal
        }
    }

    /// The web's runtime status words: Off, Failed, Running, Starting, Restarting (n), Stopped, Active.
    private static func indicator(_ plugin: PluginInstallation) -> String {
        guard plugin.enabled else { return String(localized: "Off") }
        let runtime = plugin.runtime
        if !runtime.resident {
            return runtime.state == "failed" ? String(localized: "Failed") : String(localized: "Active")
        }
        switch runtime.state {
        case "running": return String(localized: "Running")
        case "starting": return String(localized: "Starting")
        case "backoff": return String(localized: "Restarting (\(runtime.restartCount))")
        case "failed": return String(localized: "Failed")
        default: return String(localized: "Stopped")
        }
    }

    /// Whether a global setting has a saved value: a configured secret, or any saved value that is not
    /// null or a blank string. `false` and `0` count; they are values someone chose.
    private static func isSaved(_ key: String, in plugin: PluginInstallation) -> Bool {
        guard let saved = plugin.globalConfigs.first(where: { $0.key == key }) else { return false }
        if !saved.configuredSecrets.isEmpty { return true }
        return saved.value.values.contains { value in
            switch value {
            case .null: false
            case .string(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: true
            }
        }
    }

    /// The presentation's display name, else one derived from the id: "silo.tmdb-provider" is "Tmdb Provider".
    private static func displayName(_ plugin: PluginInstallation) -> String {
        if let name = plugin.presentation?.displayName.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        var rest = Substring(plugin.pluginId)
        if rest.hasPrefix("silo") {
            rest = rest.dropFirst(4)
            if let first = rest.first, "._-".contains(first) { rest = rest.dropFirst() }
        }
        let words = rest.split(whereSeparator: { "._-".contains($0) })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? plugin.pluginId : words.joined(separator: " ")
    }
}

/// The filter chips of the installed list, and its order and search.
enum PluginFilter: CaseIterable, Identifiable {
    case all, attention, update, off

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .attention: String(localized: "Needs attention")
        case .update: String(localized: "Update available")
        case .off: String(localized: "Off")
        }
    }

    func matches(_ plugin: PluginInstallation) -> Bool {
        let row = PluginPresentation(plugin)
        switch self {
        case .all: return true
        case .attention: return row.needsAttention
        case .update: return row.pendingUpdate != nil
        case .off: return !plugin.enabled
        }
    }

    func apply(to plugins: [PluginInstallation]) -> [PluginInstallation] { plugins.filter(matches) }
    func count(in plugins: [PluginInstallation]) -> Int { plugins.filter(matches).count }

    static func search(_ query: String, in plugins: [PluginInstallation]) -> [PluginInstallation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return plugins }
        return plugins.filter { PluginPresentation($0).searchText.contains(needle) }
    }

    static func sorted(_ plugins: [PluginInstallation]) -> [PluginInstallation] {
        plugins
            .map { (plugin: $0, row: PluginPresentation($0)) }
            .sorted { left, right in
                if left.row.rank != right.row.rank { return left.row.rank < right.row.rank }
                return left.row.name.localizedCaseInsensitiveCompare(right.row.name) == .orderedAscending
            }
            .map(\.plugin)
    }
}
