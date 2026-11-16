import Foundation
@testable import BloemAdmin

/// v2 user payloads that carry every field the `AdminUser` schema lists as required, including
/// the nested `effective_policy`.
enum UserFixtures {
    static func policy(overrides: [String: Any] = [:]) -> [String: Any] {
        var policy: [String: Any] = [
            "library_ids": ["1", "2"],
            "max_playback_quality": "1080p",
            "max_streams": 8,
            "max_transcodes": 4,
            "max_remote_stream_bitrate_kbps": 0,
            "max_local_stream_bitrate_kbps": 0,
            "max_profiles": 5,
            "transcode_allowed": true,
            "audio_transcode_allowed": true,
            "download_allowed": true,
            "download_transcode_allowed": false,
            "requests_allowed": false,
            "permissions": ["marker_edit"],
        ]
        policy.merge(overrides) { _, new in new }
        return policy
    }

    static func user(
        id: String = "42",
        username: String = "alice",
        enabled: Bool = true,
        overrides: [String: Any] = [:]
    ) -> [String: Any] {
        var user: [String: Any] = [
            "id": id,
            "username": username,
            "email": "\(username)@example.test",
            "role": "user",
            "permissions": [String](),
            "enabled": enabled,
            "library_ids": NSNull(),
            "max_playback_quality": NSNull(),
            "max_streams": 3,
            "max_transcodes": NSNull(),
            "max_remote_stream_bitrate_kbps": NSNull(),
            "max_local_stream_bitrate_kbps": NSNull(),
            "transcode_allowed": NSNull(),
            "audio_transcode_allowed": false,
            "max_profiles": 5,
            "download_allowed": true,
            "download_transcode_allowed": NSNull(),
            "requests_allowed": NSNull(),
            "access_group_id": NSNull(),
            "password_login": true,
            "password_change_required": false,
            "is_owner": false,
            "break_glass": false,
            "effective_policy": policy(),
            "created_at": "2026-01-02T03:04:05.678Z",
            "updated_at": "2026-01-02T03:04:05.678Z",
            "last_active_at": NSNull(),
        ]
        user.merge(overrides) { _, new in new }
        return user
    }

    /// A v2 list envelope; `next` makes it a page with more to come.
    static func page(_ items: [[String: Any]], next: String? = nil) -> [String: Any] {
        guard let next else { return ["items": items, "page": ["has_more": false]] }
        return ["items": items, "page": ["has_more": true, "next_cursor": next]]
    }

    static func response(_ object: Any, status: Int = 200, etag: String? = nil) -> MockHTTPResponse {
        MockHTTPResponse(json: object, status: status, headers: etag.map { ["ETag": $0] } ?? [:])
    }

    static let conflict = MockHTTPResponse(
        data: Data(#"{"type":"https://example.test/problems/precondition_failed","title":"Precondition Failed","status":412,"detail":"The user changed."}"#.utf8),
        status: 412,
        headers: ["Content-Type": "application/problem+json"]
    )

    static func decoded(_ user: [String: Any] = user()) throws -> AdminUser {
        try JSONDecoder.iso8601.decode(AdminUser.self, from: JSONSerialization.data(withJSONObject: user))
    }
}
