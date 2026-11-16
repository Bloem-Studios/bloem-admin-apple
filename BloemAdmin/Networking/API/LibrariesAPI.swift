import Foundation

private struct ScanStartRequest: Encodable { let libraryID: String
    enum CodingKeys: String, CodingKey { case libraryID = "library_id" }
}

private struct ScanStopAnswer: Decodable {
    let cancelled: Int
}

private struct ScanCapability: Decodable {
    let state: String
}

private struct LibraryRefreshRequest: Encodable { let mode: String }

extension APIClient {
    /// How many finished runs "Recent scans" shows.
    static let recentScanLimit = 20
    static let activeScanLimit = 50
    private static let refreshJobLimit = 50

    private static func libraryPath(_ id: String, _ suffix: String) -> String {
        "/api/v2/libraries/\(APIPath.segment(id))\(suffix)"
    }

    /// `GET /api/v2/libraries`; the list is not paginated.
    func listAdminLibraries() async throws -> [AdminLibrary] {
        let collection: APICollection<AdminLibrary> = try await getCollection("/api/v2/libraries")
        return collection.items
    }

    /// `GET /api/v2/scan/capabilities`: whether the server can start and stop scans.
    func scanControlsAvailable() async throws -> Bool {
        let capability: ScanCapability = try await get("/api/v2/scan/capabilities")
        return capability.state == "available"
    }

    /// `GET /api/v2/admin/autoscan/scans`, one status at most, newest first.
    func scanRuns(status: String?, limit: Int) async throws -> [ScanRun] {
        var query = ["limit": String(limit)]
        if let status { query["status"] = status }
        let collection: APICollection<ScanRun> = try await getCollection("/api/v2/admin/autoscan/scans", query: query)
        return collection.items
    }

    /// `POST /api/v2/scan`. The server answers only that the scan was accepted; the scan runs say how it went.
    func startScan(libraryID: String) async throws {
        try await post("/api/v2/scan", body: ScanStartRequest(libraryID: libraryID))
    }

    /// `POST /api/v2/scan/cancel`; the number of queued or local scans stopped.
    func stopScans(libraryID: String) async throws -> Int {
        let answer: ScanStopAnswer = try await post("/api/v2/scan/cancel", body: ScanStartRequest(libraryID: libraryID))
        return answer.cancelled
    }

    /// `POST /api/v2/libraries/{id}/check-mount`.
    func checkMount(libraryID: String) async throws -> MountCheck {
        try await postForResult(Self.libraryPath(libraryID, "/check-mount"))
    }

    /// `POST /api/v2/libraries/{id}/refresh-metadata`; answers 202 with the job.
    func refreshLibraryMetadata(libraryID: String, mode: LibraryRefreshMode) async throws -> LibraryRefreshJob {
        try await post(Self.libraryPath(libraryID, "/refresh-metadata"), body: LibraryRefreshRequest(mode: mode.serverValue))
    }

    /// `GET /api/v2/admin/jobs?kind=library_refresh`, newest first.
    func libraryRefreshJobs() async throws -> [LibraryRefreshJob] {
        let collection: APICollection<LibraryRefreshJob> = try await getCollection(
            "/api/v2/admin/jobs", query: ["kind": "library_refresh", "limit": String(Self.refreshJobLimit)]
        )
        return collection.items
    }

    /// `POST /api/v2/admin/jobs/{id}/cancel`.
    func cancelAdminJob(id: String) async throws {
        try await post("/api/v2/admin/jobs/\(APIPath.segment(id))/cancel")
    }
}
