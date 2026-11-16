import Foundation

/// `GET /api/v2/admin/settings/restart-keys`: the keys (and key prefixes) the server reads only at
/// startup, so a change to one waits for a restart.
struct RestartKeys: Decodable, Equatable, Sendable {
    let keys: [String]
    let prefixes: [String]

    static let none = RestartKeys(keys: [], prefixes: [])
}

/// `GET /api/v2/admin/settings/sensitive-status`: which secret settings hold a value, and which are
/// set by the server's environment (read-only here). The values themselves are never sent.
struct SensitiveStatus: Decodable, Equatable, Sendable {
    let configured: [String]
    let managedByEnv: [String]

    static let none = SensitiveStatus(configured: [], managedByEnv: [])

    enum CodingKeys: String, CodingKey {
        case configured
        case managedByEnv = "managed_by_env"
    }
}

/// What `PUT /api/v2/admin/settings` answers: the values as saved, whether a restart is needed for any
/// of them, and the `ETag` of the settings snapshot the write produced (the next `If-Match`).
struct SettingsWriteResult: Equatable, Sendable {
    let values: [String: String]
    let restartRequired: Bool
    let restartRequiredKeys: [String]
    let validator: String?
}

private struct SettingsWriteBody: Encodable {
    let values: [String: String]
}

private struct SettingsWriteWire: Decodable {
    let values: [String: String]
    let restartRequired: Bool
    let restartRequiredKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case values
        case restartRequired = "restart_required"
        case restartRequiredKeys = "restart_required_keys"
    }
}

/// The answer of a connection check or a test message: pass or fail, in the server's own words.
struct TestOutcome: Equatable, Sendable {
    let passed: Bool
    let message: String
    let durationMS: Int64?
    /// Named steps of a longer check (the sign-in provider test); empty for the others.
    let steps: [Step]

    struct Step: Equatable, Sendable, Identifiable {
        let id: String
        let label: String
        let passed: Bool
        let message: String
    }

    init(passed: Bool, message: String, durationMS: Int64? = nil, steps: [Step] = []) {
        self.passed = passed
        self.message = message
        self.durationMS = durationMS
        self.steps = steps
    }
}

private struct ConnectionCheckBody: Encodable {
    let values: [String: String]
    let dirtyKeys: [String]

    enum CodingKeys: String, CodingKey {
        case values
        case dirtyKeys = "dirty_keys"
    }
}

private struct ConnectionCheckWire: Decodable {
    let success: Bool
    let message: String
}

private struct EmailTestBody: Encodable {
    let to: String
}

private struct EmailTestWire: Decodable {
    let ok: Bool
    let durationMs: Int64?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case durationMs = "duration_ms"
        case message
    }
}

private struct ChannelTestWire: Decodable {
    let ok: Bool
    let httpStatus: Int?
    let durationMs: Int64?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case httpStatus = "http_status"
        case durationMs = "duration_ms"
        case message
    }
}

/// A server notification channel (Discord or a webhook) as the settings pages list it.
struct NotificationServerChannel: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let type: String
    let urlHost: String
    let enabled: Bool
    let consecutiveFailures: Int
    let disabledReason: String?
    let lastFailureMessage: String?
    let lastFailureAt: Date?
    let lastSuccessAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, type, enabled
        case urlHost = "url_host"
        case consecutiveFailures = "consecutive_failures"
        case disabledReason = "disabled_reason"
        case lastFailureMessage = "last_failure_message"
        case lastFailureAt = "last_failure_at"
        case lastSuccessAt = "last_success_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        urlHost = try c.decodeIfPresent(String.self, forKey: .urlHost) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        disabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason)
        lastFailureMessage = try c.decodeIfPresent(String.self, forKey: .lastFailureMessage)
        lastFailureAt = try c.decodeIfPresent(Date.self, forKey: .lastFailureAt)
        lastSuccessAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
    }

    init(id: String, name: String, type: String = "discord", urlHost: String = "", enabled: Bool = true,
         consecutiveFailures: Int = 0, disabledReason: String? = nil, lastFailureMessage: String? = nil,
         lastFailureAt: Date? = nil, lastSuccessAt: Date? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.urlHost = urlHost
        self.enabled = enabled
        self.consecutiveFailures = consecutiveFailures
        self.disabledReason = disabledReason
        self.lastFailureMessage = lastFailureMessage
        self.lastFailureAt = lastFailureAt
        self.lastSuccessAt = lastSuccessAt
    }
}

/// An installed single sign-on plugin, reduced to what the provider test needs.
struct SignInProvider: Decodable, Equatable, Identifiable, Sendable {
    /// The plugin installation's id, as the test route takes it.
    let id: String
    let name: String
    let capabilityID: String
    /// `oauth`, `credentials` or `network`.
    let signInMode: String?
    let enabled: Bool

    private struct Capability: Decodable {
        let type: String
        let id: String
        let displayName: String?
        let signInMode: String?

        enum CodingKeys: String, CodingKey {
            case type, id
            case displayName = "display_name"
            case signInMode = "sign_in_mode"
        }
    }

    private struct Binding: Decodable {
        let capabilityID: String
        let enabled: Bool

        enum CodingKeys: String, CodingKey {
            case capabilityID = "capability_id"
            case enabled
        }
    }

    private struct Presentation: Decodable {
        let displayName: String?

        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }

    private enum CodingKeys: String, CodingKey {
        case id, capabilities, presentation
        case pluginID = "plugin_id"
        case authBindings = "auth_bindings"
    }

    /// Reads one installation; throws `SignInProvider.NotASignInPlugin` for a plugin with no
    /// `auth_provider.v1` capability, which the list decoding skips.
    struct NotASignInPlugin: Error {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let capabilities = try c.decodeIfPresent([Capability].self, forKey: .capabilities) ?? []
        guard let capability = capabilities.first(where: { $0.type == "auth_provider.v1" }) else {
            throw NotASignInPlugin()
        }
        let bindings = try c.decodeIfPresent([Binding].self, forKey: .authBindings) ?? []
        let presentation = try c.decodeIfPresent(Presentation.self, forKey: .presentation)
        let pluginID = try c.decodeIfPresent(String.self, forKey: .pluginID) ?? ""
        id = try c.decode(String.self, forKey: .id)
        capabilityID = capability.id
        signInMode = capability.signInMode
        enabled = bindings.first(where: { $0.capabilityID == capability.id })?.enabled ?? false
        let named = [presentation?.displayName, capability.displayName, pluginID].compactMap { $0 }.first { !$0.isEmpty }
        name = named ?? pluginID
    }

    init(id: String, name: String, capabilityID: String, signInMode: String? = "oauth", enabled: Bool) {
        self.id = id
        self.name = name
        self.capabilityID = capabilityID
        self.signInMode = signInMode
        self.enabled = enabled
    }
}

/// Reads a list while skipping the elements that are not sign-in plugins.
private struct SignInProviderList: Decodable {
    let providers: [SignInProvider]

    private enum CodingKeys: String, CodingKey { case items }

    private struct Skippable: Decodable {
        let provider: SignInProvider?
        init(from decoder: Decoder) throws {
            provider = try? SignInProvider(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decode([Skippable].self, forKey: .items).compactMap(\.provider)
    }
}

private struct SignInTestBody: Encodable {
    let capabilityID: String

    enum CodingKeys: String, CodingKey { case capabilityID = "capability_id" }
}

private struct SignInTestWire: Decodable {
    struct Step: Decodable {
        let id: String
        let label: String
        let ok: Bool
        let message: String
    }

    let ok: Bool
    let steps: [Step]
}

extension APIClient {
    /// `GET /api/v2/admin/settings/restart-keys`.
    func restartKeys() async throws -> RestartKeys {
        try await get("/api/v2/admin/settings/restart-keys")
    }

    /// `GET /api/v2/admin/settings/sensitive-status`.
    func sensitiveStatus() async throws -> SensitiveStatus {
        try await get("/api/v2/admin/settings/sensitive-status")
    }

    /// `PUT /api/v2/admin/settings` with `{"values": {...}}` and `If-Match`: several settings in one
    /// atomic write. Never replayed. A 412 means the settings changed since `validator` was read.
    func updateSettings(values: [String: String], validator: String) async throws -> SettingsWriteResult {
        let (wire, etag): (SettingsWriteWire, String?) = try await putConditionalDecodingWithValidator(
            "/api/v2/admin/settings", body: SettingsWriteBody(values: values), validator: validator
        )
        return SettingsWriteResult(
            values: wire.values, restartRequired: wire.restartRequired,
            restartRequiredKeys: wire.restartRequiredKeys ?? [], validator: etag
        )
    }

    /// `POST /api/v2/admin/settings/check/{kind}`: one connection check against the values in `values`
    /// (the unsaved ones, named again in `dirtyKeys`); keys not named use what the server has stored.
    func checkConnection(kind: String, values: [String: String], dirtyKeys: [String]) async throws -> TestOutcome {
        let wire: ConnectionCheckWire = try await post(
            "/api/v2/admin/settings/check/\(APIPath.segment(kind))",
            body: ConnectionCheckBody(values: values, dirtyKeys: dirtyKeys)
        )
        return TestOutcome(passed: wire.success, message: wire.message)
    }

    /// `POST /api/v2/admin/email/test`: sends one real message through the saved mail settings.
    func sendTestEmail(to address: String) async throws -> TestOutcome {
        let wire: EmailTestWire = try await post("/api/v2/admin/email/test", body: EmailTestBody(to: address))
        return TestOutcome(passed: wire.ok, message: wire.message ?? "", durationMS: wire.durationMs)
    }

    /// `GET /api/v2/admin/notifications/server-channels` (every page).
    func notificationServerChannels() async throws -> [NotificationServerChannel] {
        try await readAllPages("/api/v2/admin/notifications/server-channels")
    }

    /// `POST /api/v2/admin/notifications/server-channels/{id}/test`: one sample message to the channel.
    func testServerChannel(id: String) async throws -> TestOutcome {
        let wire: ChannelTestWire = try await postForResult("/api/v2/admin/notifications/server-channels/\(APIPath.segment(id))/test")
        return TestOutcome(passed: wire.ok, message: wire.message ?? "", durationMS: wire.durationMs)
    }

    /// `GET /api/v2/admin/plugins/installations`, reduced to the single sign-on plugins.
    func signInProviders() async throws -> [SignInProvider] {
        let list: SignInProviderList = try await get("/api/v2/admin/plugins/installations", query: ["limit": "200"])
        return list.providers.filter { $0.signInMode != "network" }
    }

    /// `POST /api/v2/admin/plugins/installations/{id}/auth-binding/test`: the plugin's own connection
    /// test on its saved configuration. A failed check is a 200 answer with `ok` false.
    func testSignInProvider(_ provider: SignInProvider) async throws -> TestOutcome {
        let wire: SignInTestWire = try await post(
            "/api/v2/admin/plugins/installations/\(APIPath.segment(provider.id))/auth-binding/test",
            body: SignInTestBody(capabilityID: provider.capabilityID)
        )
        let steps = wire.steps.map { TestOutcome.Step(id: $0.id, label: $0.label, passed: $0.ok, message: $0.message) }
        let failing = steps.first { !$0.passed }
        return TestOutcome(passed: wire.ok, message: failing.map { "\($0.label): \($0.message)" } ?? "", steps: steps)
    }
}
