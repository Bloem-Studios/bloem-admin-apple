import Foundation

extension APIClient {
    /// `GET /api/v2/admin/backups`: the schedule, any running operation, the last run, warnings and the
    /// saved backups.
    func backupsOverview() async throws -> BackupsOverview {
        try await get("/api/v2/admin/backups")
    }

    /// `POST /api/v2/admin/backups`: starts a manual backup (202). Answers 409 while another backup
    /// operation holds the lock.
    func startBackup() async throws {
        try await post("/api/v2/admin/backups")
    }

    /// `DELETE /api/v2/admin/backups/{id}` (204). Answers 409 while the backup lock is held.
    func deleteBackup(id: String) async throws {
        try await delete("/api/v2/admin/backups/\(APIPath.segment(id))")
    }

    /// `GET /api/v2/admin/tasks/{key}`: one task, as the list returns it.
    func adminTask(key: String) async throws -> AdminTask {
        try await get("/api/v2/admin/tasks/\(APIPath.segment(key))")
    }
}
