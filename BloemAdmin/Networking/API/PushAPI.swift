import Foundation

/*
 Admin push registration (Bloem v2, feature token `admin_push_v1`): how this phone tells a Bloem server where to
 push, and which kinds to stop sending. The three calls here take the administrator's own sign-in (an account
 access token with a login session; the server refuses API keys and administrative-context tokens). Reading a notification's text and retiring a device use the device's display token instead and live in
 `PushDisplayAPI.swift`, because the notification service extension makes them while the phone is locked.

 A plain Silo server has none of these routes. It answers `GET /api/bloem/v2/capabilities` with 404, and the app
 never registers with it.
 */

/// The feature token a Bloem server lists in `GET /api/bloem/v2/capabilities` while the admin push routes are
/// mounted and the operator has push delivery on.
let adminPushFeatureToken = "admin_push_v1"

/// The Apple topic the server accepts for this app: its bundle id.
let adminPushAPNsTopic = "com.bloemstudios.admin"

struct PushRegisterRequest: Encodable, Equatable, Sendable {
    /// Generated once per installation and kept across token refreshes and sign-ins.
    let installationID: String
    let platform: String
    /// The APNs device token, hex.
    let token: String
    /// `sandbox` or `production`, as the build's `aps-environment`.
    let apnsEnvironment: String
    let apnsTopic: String
    /// The server-sent kinds this device has switched off. Replaces the server's stored switches when present.
    let disabledKinds: [String]?
    /// Whether at least one widget is placed. Only a device that says so gets widget wakes. Omitted keeps what the
    /// server holds; false clears its channels.
    var widgetsPlaced: Bool? = nil
    /// What the placed widgets show (`sessions`, `requests`, `libraries`, `nodes`). Sent, and not empty, only when
    /// `widgetsPlaced` is true.
    var widgetChannels: [String]? = nil

    private enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case platform, token
        case apnsEnvironment = "apns_environment"
        case apnsTopic = "apns_topic"
        case disabledKinds = "disabled_kinds"
        case widgetsPlaced = "widgets_placed"
        case widgetChannels = "widget_channels"
    }
}

struct PushKindState: Decodable, Equatable, Sendable {
    let kind: String
    let enabled: Bool
    let serverEmitted: Bool

    private enum CodingKeys: String, CodingKey {
        case kind, enabled
        case serverEmitted = "server_emitted"
    }

    init(kind: String, enabled: Bool, serverEmitted: Bool = false) {
        self.kind = kind
        self.enabled = enabled
        self.serverEmitted = serverEmitted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        serverEmitted = try c.decodeIfPresent(Bool.self, forKey: .serverEmitted) ?? false
    }
}

struct PushRegistered: Decodable, Equatable, Sendable {
    /// Prefixes every delivery id pushed to this device.
    let deviceID: String
    /// Reads this device's notification text and retires it; replaced by the next registration.
    let displayToken: String
    let kinds: [PushKindState]
    /// The widgets the server now holds for this device. nil when the answer has no such fields: a server that
    /// does not send widget wakes.
    let widgets: WidgetReport?

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case displayToken = "display_token"
        case kinds
        case widgetsPlaced = "widgets_placed"
        case widgetChannels = "widget_channels"
    }

    init(deviceID: String, displayToken: String, kinds: [PushKindState] = [], widgets: WidgetReport? = nil) {
        self.deviceID = deviceID
        self.displayToken = displayToken
        self.kinds = kinds
        self.widgets = widgets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        displayToken = try c.decode(String.self, forKey: .displayToken)
        kinds = try c.decodeIfPresent([PushKindState].self, forKey: .kinds) ?? []
        if let placed = try c.decodeIfPresent(Bool.self, forKey: .widgetsPlaced) {
            let names = try c.decodeIfPresent([String].self, forKey: .widgetChannels) ?? []
            widgets = WidgetReport(placed: placed, channels: Set(names.compactMap(WidgetChannel.init(rawValue:))))
        } else {
            widgets = nil
        }
    }
}

struct PushKindsRequest: Encodable, Equatable, Sendable {
    /// Kind id to enabled. Kinds not named keep their setting.
    let kinds: [String: Bool]
}

struct PushKindsResponse: Decodable, Equatable, Sendable {
    let kinds: [PushKindState]
}

/// `PUT .../devices/{device_id}/widgets`: which widgets the phone has placed. Sent whenever a widget is added or
/// removed; `widgets_placed` false when the last is gone.
struct PushWidgetsRequest: Encodable, Equatable, Sendable {
    let widgetsPlaced: Bool
    /// Required, and not empty, when `widgetsPlaced` is true; the server ignores it otherwise.
    let channels: [String]

    private enum CodingKeys: String, CodingKey {
        case widgetsPlaced = "widgets_placed"
        case channels
    }
}

struct PushWidgetsResponse: Decodable, Equatable, Sendable {
    let widgetsPlaced: Bool
    let channels: [String]

    private enum CodingKeys: String, CodingKey {
        case widgetsPlaced = "widgets_placed"
        case channels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        widgetsPlaced = try c.decode(Bool.self, forKey: .widgetsPlaced)
        channels = try c.decodeIfPresent([String].self, forKey: .channels) ?? []
    }

    /// What the server now holds, as the app's own type.
    var report: WidgetReport {
        WidgetReport(placed: widgetsPlaced, channels: Set(channels.compactMap(WidgetChannel.init(rawValue:))))
    }
}

extension APIClient {
    /// Registers or refreshes this installation. Registering again with the same installation id keeps the
    /// device id and the per-kind switches, replaces the token and mints a new display token.
    func registerPushDevice(_ request: PushRegisterRequest) async throws -> PushRegistered {
        try await post(PushPaths.devices, body: request)
    }

    /// Tells the server which kinds to stop (or resume) sending to this device.
    func setPushKinds(deviceID: String, kinds: [String: Bool]) async throws -> PushKindsResponse {
        try await patch(PushPaths.kinds(deviceID: deviceID), body: PushKindsRequest(kinds: kinds))
    }

    /// Tells the server which widgets this phone has placed, so it sends widget wakes for them and nothing else.
    func setPushWidgets(deviceID: String, report: WidgetReport) async throws -> PushWidgetsResponse {
        try await put(
            PushPaths.widgets(deviceID: deviceID),
            body: PushWidgetsRequest(widgetsPlaced: report.placed, channels: report.channelNames)
        )
    }

    /// Removes this device with the administrator's sign-in. Retiring with the display token needs none.
    func deletePushDevice(deviceID: String) async throws {
        try await delete(PushPaths.device(deviceID))
    }
}
