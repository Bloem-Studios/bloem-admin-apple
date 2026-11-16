import Foundation

/// The receipt of `PUT /api/v2/admin/settings/{key}`. The server leaves `restart_required` out
/// when no restart is needed.
struct SettingReceipt: Decodable, Equatable, Sendable {
    let key: String
    let value: String
    let restartRequired: Bool

    enum CodingKeys: String, CodingKey {
        case key, value
        case restartRequired = "restart_required"
    }

    init(key: String, value: String, restartRequired: Bool) {
        self.key = key
        self.value = value
        self.restartRequired = restartRequired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        value = try container.decode(String.self, forKey: .value)
        restartRequired = try container.decodeIfPresent(Bool.self, forKey: .restartRequired) ?? false
    }
}

extension APIClient {
    /// `GET /api/v2/admin/settings`: every visible stored setting as key to value.
    func settings() async throws -> [AdminSetting] {
        let raw: [String: String] = try await get("/api/v2/admin/settings")
        return raw.map { AdminSetting(key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }
    }

    /// `GET /api/v2/admin/settings/effective`: every visible setting, defaults included, with the
    /// `ETag` of the whole settings snapshot. That tag is the validator for a write to any one key;
    /// `GET /settings/{key}` sends none.
    func effectiveSettings() async throws -> (values: [String: String], validator: String?) {
        let (values, validator): ([String: String], String?) = try await getWithValidator("/api/v2/admin/settings/effective")
        return (values, validator)
    }

    /// `PUT /api/v2/admin/settings/{key}` with `If-Match`; never replayed. Answers the receipt,
    /// which says whether the change waits for a restart.
    func updateSetting(key: String, value: String, validator: String) async throws -> SettingReceipt {
        try await putConditionalDecoding(
            "/api/v2/admin/settings/\(APIPath.segment(key))",
            body: UpdateSettingRequest(value: value),
            validator: validator
        )
    }
}
