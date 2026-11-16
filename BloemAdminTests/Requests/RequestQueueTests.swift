import XCTest
@testable import BloemAdmin

/// The web admin queue's rules (`requestQueueModel.ts`, `lib/mediaRequests.ts`), so the app and the web
/// agree on where a request sits and what can be done with it.
final class RequestQueueTests: XCTestCase {
    private func request(
        status: String = "pending", outcome: String = "active", state: String? = nil,
        targets: [RequestTarget] = [], lastError: String? = nil, outcomeReason: String? = nil,
        mediaType: String = "movie", seasons: [Int] = [], year: Int? = nil, requestedBy: String? = "7"
    ) -> MediaRequest {
        MediaRequest(
            id: "r1", provider: "tmdb", mediaType: mediaType, title: "Dune", status: status, outcome: outcome,
            requestedByUserID: requestedBy, lastError: lastError, state: state, outcomeReason: outcomeReason,
            year: year, seasons: seasons, targets: targets
        )
    }

    private let sent = RequestTarget(id: "t1", quality: "4K", status: "queued")

    func testEachRequestBelongsToTheViewTheServerPutsItIn() {
        XCTAssertEqual(RequestQueue.view(for: request(status: "pending")), .needsApproval)
        XCTAssertEqual(RequestQueue.view(for: request(status: "approved")), .inProgress)
        XCTAssertEqual(RequestQueue.view(for: request(status: "queued")), .inProgress)
        XCTAssertEqual(RequestQueue.view(for: request(status: "downloading")), .inProgress)
        XCTAssertEqual(RequestQueue.view(for: request(status: "completed")), .done)
        XCTAssertEqual(RequestQueue.view(for: request(status: "queued", outcome: "failed")), .failed)
        XCTAssertEqual(RequestQueue.view(for: request(status: "pending", outcome: "declined")), .done)
        XCTAssertEqual(RequestQueue.view(for: request(status: "approved", outcome: "cancelled")), .done)
    }

    func testActionsFollowTheViewAndWhetherAnythingWasSent() {
        XCTAssertEqual(RequestQueue.actions(for: request(status: "pending")), [.approve, .decline])
        XCTAssertEqual(RequestQueue.actions(for: request(status: "approved")), [.cancel])
        XCTAssertEqual(RequestQueue.actions(for: request(status: "approved", targets: [sent])), [])
        XCTAssertEqual(RequestQueue.actions(for: request(status: "downloading", targets: [sent])), [])
        XCTAssertEqual(RequestQueue.actions(for: request(status: "queued", outcome: "failed", targets: [sent])), [.retry, .cancel])
        XCTAssertEqual(RequestQueue.actions(for: request(status: "completed")), [])
        XCTAssertEqual(RequestQueue.actions(for: request(status: "pending", outcome: "declined")), [])
    }

    func testTheQueueOpensOnWhatNeedsApprovalElseWhatIsUnderWay() {
        XCTAssertEqual(RequestQueue.defaultView(RequestCounts(needsApproval: 2, inProgress: 5, failed: 1, done: 9)), .needsApproval)
        XCTAssertEqual(RequestQueue.defaultView(RequestCounts(needsApproval: 0, inProgress: 5, failed: 1, done: 9)), .inProgress)
        XCTAssertEqual(RequestQueue.defaultView(nil), .inProgress)
    }

    func testTheStateBadgePrefersTheServersOwnState() {
        XCTAssertEqual(RequestQueue.displayState(request(status: "queued", state: "partially_available")), .partiallyAvailable)
        XCTAssertEqual(RequestQueue.displayState(request(status: "queued", outcome: "failed")), .failed)
        XCTAssertEqual(RequestQueue.displayState(request(status: "downloading")), .processing)
        XCTAssertEqual(RequestQueue.displayState(request(status: "completed")), .available)
        XCTAssertEqual(RequestQueue.displayState(request(status: "pending", state: "something-new")), .pending)
        XCTAssertNil(RequestQueue.displayState(request(status: "unknown")))
    }

    func testTheErrorThatStoppedARequestWinsOverItsClosingReason() {
        let both = RequestQueue.problem(request(lastError: "Radarr refused it", outcomeReason: "duplicate"))
        XCTAssertEqual(both?.text, "Radarr refused it")
        XCTAssertEqual(both?.isError, true)
        let reason = RequestQueue.problem(request(outcomeReason: "duplicate"))
        XCTAssertEqual(reason?.text, "duplicate")
        XCTAssertEqual(reason?.isError, false)
        XCTAssertNil(RequestQueue.problem(request()))
    }

    func testSeasonsReadAsRunsLikeTheWeb() {
        XCTAssertNil(RequestQueue.seasonList([]))
        XCTAssertEqual(RequestQueue.seasonList([2]), "Season 2")
        XCTAssertEqual(RequestQueue.seasonList([3, 1, 2, 5, 2]), "Seasons 1–3, 5")
    }

    func testTheMetaLineNamesYearTypeAndSeasons() {
        XCTAssertEqual(RequestQueue.metaLine(request(year: 2021)), "2021 · Movie")
        XCTAssertEqual(RequestQueue.metaLine(request(mediaType: "series", seasons: [1, 2])), "Series · Seasons 1–2")
    }

    func testTheRequesterFallsBackToTheAccountNumberThenUnknown() {
        XCTAssertEqual(RequestQueue.requesterLabel(request(), names: ["7": "alex"]), "alex")
        XCTAssertEqual(RequestQueue.requesterLabel(request(), names: [:]), "User 7")
        XCTAssertEqual(RequestQueue.requesterLabel(request(requestedBy: nil), names: [:]), "Unknown account")
    }

    func testAnUnknownHistoryTypeShowsAsItIs() {
        XCTAssertEqual(RequestQueue.eventLabel("status_approved"), "Approved")
        XCTAssertEqual(RequestQueue.eventLabel("status_queued"), "Sent to the server")
        XCTAssertEqual(RequestQueue.eventLabel("something_new"), "something_new")
    }

    func testAnUnknownDownloadPhaseReadsAsDownloadingWithoutAPercentage() {
        XCTAssertEqual(RequestQueue.downloadPercent(RequestDownload(phase: "downloading", percent: 42)), 42)
        XCTAssertEqual(RequestQueue.downloadPercent(RequestDownload(phase: "downloading", percent: 140)), 100)
        XCTAssertNil(RequestQueue.downloadPercent(RequestDownload(phase: "warping", percent: 42)))
        XCTAssertEqual(RequestQueue.downloadPhaseLabel("warping"), "Downloading")
        XCTAssertEqual(RequestQueue.downloadPhaseLabel("import_blocked"), "Import blocked")
    }

    func testTargetsNameTheirServerElseItsKind() {
        XCTAssertEqual(RequestQueue.targetServerName(RequestTarget(id: "t", quality: "HD", status: "queued", instanceName: "Radarr 4K", integrationKind: "radarr")), "Radarr 4K")
        XCTAssertEqual(RequestQueue.targetServerName(RequestTarget(id: "t", quality: "HD", status: "queued", integrationKind: "radarr")), "radarr")
        XCTAssertEqual(RequestQueue.targetServerName(RequestTarget(id: "t", quality: "HD", status: "queued")), "Unknown server")
    }

    func testPostersComeFromTMDBOnlyForAPath() {
        XCTAssertEqual(RequestQueue.posterURL("/abc.jpg")?.absoluteString, "https://image.tmdb.org/t/p/w92/abc.jpg")
        XCTAssertNil(RequestQueue.posterURL(nil))
        XCTAssertNil(RequestQueue.posterURL("https://elsewhere.test/x.jpg"))
    }

    func testCancellingAFailedRequestClosesIt() {
        XCTAssertEqual(RequestQueue.reasonPrompt(.cancel, request: request(status: "queued", outcome: "failed"))?.title, "Close request")
        XCTAssertEqual(RequestQueue.reasonPrompt(.cancel, request: request(status: "approved"))?.title, "Cancel request")
        XCTAssertEqual(RequestQueue.reasonPrompt(.decline, request: request())?.confirm, "Decline")
        XCTAssertNil(RequestQueue.reasonPrompt(.approve, request: request()))
    }

    func testAFullRequestDecodesWithItsTargetsAndDates() throws {
        let json = #"""
        {"id":"r9","provider":"tmdb","media_type":"series","tmdb_id":1399,"title":"Show","year":2011,
         "poster_path":"/p.jpg","status":"downloading","outcome":"active","state":"processing","seasons":[1,2],
         "season_progress":[],"source":"watchlist","is_anime":false,"requested_by_user_id":"7",
         "created_at":"2026-11-01T10:00:00.000Z","updated_at":"2026-11-01T10:00:00.000Z","approved_at":"2026-11-01T11:00:00Z",
         "last_error":"  ","outcome_reason":"",
         "targets":[{"id":"t1","request_id":"r9","quality":"4K","status":"downloading","is_anime":false,
                     "instance_name":"Sonarr 4K","route_name":"Big screens","created_at":"2026-11-01T11:00:00.000Z",
                     "updated_at":"2026-11-01T11:00:00.000Z",
                     "download":{"phase":"downloading","percent":37,"downloads":2,"updated_at":"2026-11-01T11:05:00.000Z"}}]}
        """#
        let decoded = try JSONDecoder().decode(MediaRequest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.year, 2011)
        XCTAssertEqual(decoded.seasons, [1, 2])
        XCTAssertEqual(decoded.source, "watchlist")
        XCTAssertEqual(decoded.tmdbID, 1399)
        XCTAssertNil(decoded.lastError, "a blank error is no error")
        XCTAssertNil(decoded.outcomeReason)
        XCTAssertNotNil(decoded.createdAt)
        XCTAssertNotNil(decoded.approvedAt, "a date without fractional seconds still reads")
        XCTAssertEqual(decoded.targets.first?.routeName, "Big screens")
        XCTAssertEqual(decoded.targets.first?.download, RequestDownload(phase: "downloading", percent: 37))
    }

    func testAMinimalRequestStillDecodes() throws {
        let json = #"{"id":"r1","provider":"tmdb","media_type":"movie","title":"X","status":"pending","outcome":"active"}"#
        let decoded = try JSONDecoder().decode(MediaRequest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.targets, [])
        XCTAssertEqual(decoded.source, "direct")
        XCTAssertNil(decoded.createdAt)
    }
}
