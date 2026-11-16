import Foundation

/// `GET /api/v2/admin/tasks/{key}/triggers`.
struct TaskSchedule: Decodable, Sendable {
    let taskKey: String
    let triggers: [TaskTrigger]

    enum CodingKeys: String, CodingKey {
        case taskKey = "task_key"
        case triggers
    }
}

/// Body of `PUT /api/v2/admin/tasks/{key}/triggers`; replaces the whole trigger set.
struct UpdateScheduleRequest: Encodable, Sendable {
    let triggers: [TaskTrigger]
}

extension APIClient {
    private static func taskPath(_ key: String, _ suffix: String = "") -> String {
        "/api/v2/admin/tasks/\(APIPath.segment(key))\(suffix)"
    }

    /// Every task. The route declares only `include_hidden` and no paging, and the server answers
    /// 422 to a `limit` or `cursor`, so this is one request with no query.
    func tasks() async throws -> [AdminTask] {
        let collection: APICollection<AdminTask> = try await getCollection("/api/v2/admin/tasks")
        return collection.items
    }

    /// `GET /api/v2/admin/tasks/{key}/history`: finished runs, newest first, one cursor page.
    /// `limit` is 1 to 200.
    func taskHistory(key: String, cursor: String? = nil, limit: Int = 20) async throws -> APICollection<TaskExecution> {
        var query = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        return try await getCollection(Self.taskPath(key, "/history"), query: query)
    }

    func runTask(key: String) async throws {
        try await post(Self.taskPath(key, "/run"))
    }

    func cancelTask(key: String) async throws {
        try await post(Self.taskPath(key, "/cancel"))
    }

    /// The schedule plus the ETag that guards the next write to it.
    func taskSchedule(key: String) async throws -> (TaskSchedule, String?) {
        try await getWithValidator(Self.taskPath(key, "/triggers"))
    }

    /// `PUT .../triggers` with `If-Match`; never replayed.
    func updateTaskSchedule(key: String, triggers: [TaskTrigger], validator: String) async throws {
        try await putConditional(
            Self.taskPath(key, "/triggers"),
            body: UpdateScheduleRequest(triggers: triggers),
            validator: validator
        )
    }
}
