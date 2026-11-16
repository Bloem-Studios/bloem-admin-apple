import XCTest
@testable import BloemAdmin

/// The Backups page: what the status says (last success, next run, a running backup's progress,
/// warnings), the saved backups, Back up now and Delete, and the typed editor for backup.enabled,
/// backup.time and backup.keep.
@MainActor
final class BackupsTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let now = AdminTimestamp.date(from: "2026-11-15T12:00:00Z")!
    private let en = Locale(identifier: "en_US")

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func overview(
        enabled: Bool = true, busy: Bool = false, active: String? = nil, lastSuccess: String? = #""2026-11-15T10:00:00Z""#,
        lastRun: String? = nil, warnings: String = "[]", items: String = "[]", destinationAvailable: Bool = true, keep: Int = 7
    ) throws -> BackupsOverview {
        var json = #"""
        {"busy":\#(busy),"destination":"default","destination_available":\#(destinationAvailable),"enabled":\#(enabled),"encrypted":true,
         "items":\#(items),"keep":\#(keep),"key_check":"k","key_confirmed":true,"other_server_ids":[],"server_id":"s","warnings":\#(warnings)
        """#
        if let lastSuccess { json += #","last_success_at":\#(lastSuccess)"# }
        if let active { json += #","active":\#(active)"# }
        if let lastRun { json += #","last_run":\#(lastRun)"# }
        return try JSONDecoder().decode(BackupsOverview.self, from: Data((json + "}").utf8))
    }

    private func item(_ id: String, kind: String = "nightly", status: String = "complete", size: Int = 1_500_000_000, created: String = "2026-11-15T04:00:00Z") -> String {
        #"{"id":"\#(id)","kind":"\#(kind)","status":"\#(status)","created_at":"\#(created)","size_bytes":\#(size),"blob_count":3,"clean":true,"encrypted":true,"key_matches":true,"location":"x","missing_blobs":[],"missing_blobs_total":0,"objects":[],"restore_set_omitted":[]}"#
    }

    private func presentation(_ overview: BackupsOverview, next: String? = nil) -> BackupsPresentation {
        BackupsPresentation(overview: overview, taskNextRunAt: next, now: now, locale: en)
    }

    // MARK: Status

    func testLastSuccessAndNextRun() throws {
        let page = presentation(try overview(), next: "2026-11-16T04:00:00Z")
        XCTAssertEqual(page.lastSuccess, "Last successful backup 2 h ago")
        XCTAssertEqual(page.nextRun, "Next backup in 16 h")
    }

    func testNoSuccessYet() throws {
        XCTAssertEqual(presentation(try overview(lastSuccess: nil)).lastSuccess, "No successful backup yet")
    }

    func testANextRunInThePastIsNotKnownRatherThanGuessed() throws {
        XCTAssertEqual(presentation(try overview(), next: "2026-11-15T03:00:00Z").nextRun, "Next backup time is not known yet")
        XCTAssertEqual(presentation(try overview(), next: nil).nextRun, "Next backup time is not known yet")
    }

    func testOffMeansNoNextRun() throws {
        XCTAssertEqual(presentation(try overview(enabled: false), next: "2026-11-16T04:00:00Z").nextRun, "Nightly backups are off")
    }

    func testARunningBackupShowsItsProgress() throws {
        let page = presentation(try overview(busy: true, active: #"{"operation":"backup","progress":42.4,"started_at":"2026-11-15T11:58:00Z","message":"Copying files"}"#))
        XCTAssertEqual(page.activeText, "Backup running, 42%")
        XCTAssertEqual(try XCTUnwrap(page.activeProgress), 0.424, accuracy: 0.0001)
        XCTAssertEqual(page.activeMessage, "Copying files")
    }

    func testNothingRunningMeansNoActiveText() throws {
        XCTAssertNil(presentation(try overview()).activeText)
    }

    func testAFailedLastRunIsSaidWithItsError() throws {
        let page = presentation(try overview(lastRun: #"{"id":"r","kind":"nightly","started_at":"2026-11-15T04:00:00Z","finished_at":"2026-11-15T04:05:00Z","status":"failed","error":"No space left"}"#))
        XCTAssertEqual(page.lastRun, "Last run failed 7 h ago: No space left")
        XCTAssertTrue(page.lastRunFailed)
    }

    func testACompleteLastRunNeedsNoSeparateLine() throws {
        let page = presentation(try overview(lastRun: #"{"id":"r","kind":"nightly","started_at":"2026-11-15T04:00:00Z","finished_at":"2026-11-15T04:05:00Z","status":"complete"}"#))
        XCTAssertNil(page.lastRun)
    }

    func testWarningsHideTheOffNoticeAndKeepTheRest() throws {
        let page = presentation(try overview(warnings: #"[{"code":"disabled","message":"off"},{"code":"destination_unavailable","message":"Destination is down"},{"code":"no_backups_at_destination","message":"Nothing there yet"}]"#))
        XCTAssertEqual(page.warnings.map(\.text), ["Destination is down", "Nothing there yet"])
        XCTAssertEqual(page.warnings.map(\.isInformation), [false, true])
    }

    // MARK: Back up now

    func testBackUpNowIsAvailableWhenNothingBlocksIt() throws {
        XCTAssertNil(presentation(try overview()).backUpNowBlocker)
    }

    func testBackUpNowSaysWhyItCannotRun() throws {
        XCTAssertEqual(presentation(try overview(busy: true, active: #"{"operation":"backup","progress":1,"started_at":"2026-11-15T11:58:00Z"}"#)).backUpNowBlocker, "A backup is already running")
        XCTAssertEqual(presentation(try overview(busy: true, active: #"{"operation":"restore","progress":1,"started_at":"2026-11-15T11:58:00Z"}"#)).backUpNowBlocker, "A restore is running")
        XCTAssertEqual(presentation(try overview(busy: true)).backUpNowBlocker, "Another backup task is running")
        XCTAssertEqual(presentation(try overview(destinationAvailable: false)).backUpNowBlocker, "The backup destination cannot be reached")
        XCTAssertEqual(
            presentation(try overview(warnings: #"[{"code":"key_not_confirmed","message":"x"}]"#)).backUpNowBlocker,
            "Confirm the encryption key on the web before backing up"
        )
        XCTAssertEqual(
            presentation(try overview(warnings: #"[{"code":"sqlite_user_store","message":"Backups need Postgres"}]"#)).backUpNowBlocker,
            "Backups need Postgres"
        )
    }

    // MARK: Saved backups

    func testSavedBackupsAreNamedInWords() throws {
        let page = presentation(try overview(items: "[\(item("b1")),\(item("b2", kind: "manual", status: "complete_with_warnings", size: 2_048)),\(item("b3", kind: "before-restore", status: "unreadable"))]"))
        XCTAssertEqual(page.rows.map(\.kindText), ["Nightly", "Manual", "Before restore"])
        XCTAssertEqual(page.rows.map(\.statusText), ["Complete", "Complete with warnings", "Unreadable"])
        XCTAssertEqual(page.rows[0].sizeText, "1.5 GB")
        XCTAssertEqual(page.rows[0].createdText, "Created 8 h ago")
    }

    // The quality audit (2026-11-16): a backup that is unreadable or did not finish was a muted word, like a good one.
    func testABackupThatNeedsALookIsSaidWithItsToneAndAGoodOneQuietly() throws {
        let page = presentation(try overview(items: "[\(item("b1")),\(item("b2", status: "complete_with_warnings")),\(item("b3", status: "unreadable")),\(item("b4", status: "incomplete")),\(item("b5", status: "in_progress"))]"))
        XCTAssertEqual(page.rows.map(\.statusTone), [.positive, .warning, .failure, .failure, .normal])
    }

    func testDeleteIsBlockedWhileTheBackupLockIsHeld() throws {
        let free = presentation(try overview(items: "[\(item("b1"))]"))
        XCTAssertTrue(free.rows[0].canDelete)
        let busy = presentation(try overview(busy: true, items: "[\(item("b1"))]"))
        XCTAssertFalse(busy.rows[0].canDelete)
        let running = presentation(try overview(items: "[\(item("b1", status: "in_progress"))]"))
        XCTAssertFalse(running.rows[0].canDelete)
    }

    // MARK: Reads and writes

    func testLoadReadsTheBackupsAndTheBackupTaskForItsNextRun() async throws {
        http.state.stub(path: "/api/v2/admin/backups", json: try JSONSerialization.jsonObject(with: Data(#"{"busy":false,"destination":"default","destination_available":true,"enabled":true,"encrypted":false,"items":[],"keep":7,"key_check":"k","key_confirmed":true,"other_server_ids":[],"server_id":"s","warnings":[]}"#.utf8)))
        http.state.stub(path: "/api/v2/admin/tasks/backup", json: ["key": "backup", "name": "Backup", "description": "", "category": "system", "state": "idle", "progress": 0, "manual_only": false, "triggers": [Any](), "execution_scope": "process", "next_run_at": "2026-11-16T04:00:00Z"])
        let model = SectionModel<BackupsPage>.backups()

        await model.load(client: http.client)

        XCTAssertEqual(model.payload?.taskNextRunAt, "2026-11-16T04:00:00Z")
        XCTAssertEqual(model.payload?.overview.keep, 7)
    }

    func testTheBackupTaskFailingDoesNotHideTheBackups() async throws {
        http.state.stub(path: "/api/v2/admin/backups", json: try JSONSerialization.jsonObject(with: Data(#"{"busy":false,"destination":"default","destination_available":true,"enabled":true,"encrypted":false,"items":[],"keep":7,"key_check":"k","key_confirmed":true,"other_server_ids":[],"server_id":"s","warnings":[]}"#.utf8)))
        http.state.stub(path: "/api/v2/admin/tasks/backup", json: ["message": "no"], status: 500)
        let model = SectionModel<BackupsPage>.backups()

        await model.load(client: http.client)

        XCTAssertNotNil(model.payload)
        XCTAssertNil(model.payload?.taskNextRunAt)
        XCTAssertNil(model.loadFailure)
    }

    private func stubBackupList() throws {
        http.state.stub(path: "/api/v2/admin/backups", json: try JSONSerialization.jsonObject(with: Data(#"{"busy":false,"destination":"default","destination_available":true,"enabled":true,"encrypted":false,"items":[],"keep":7,"key_check":"k","key_confirmed":true,"other_server_ids":[],"server_id":"s","warnings":[]}"#.utf8)))
        http.state.stub(path: "/api/v2/admin/tasks/backup", json: ["message": "no"], status: 404)
    }

    func testBackUpNowPostsToTheBackupsRouteThenReloads() async throws {
        try stubBackupList()
        let model = SectionModel<BackupsPage>.backups()
        await model.load(client: http.client)

        let done = await model.backUpNow(client: http.client)

        XCTAssertTrue(done)
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/backups").map(\.httpMethod), ["GET", "POST", "GET"])
    }

    func testABackupAlreadyRunningIsAConflictInWords() async throws {
        try stubBackupList()
        let model = SectionModel<BackupsPage>.backups()
        await model.load(client: http.client)
        http.state.stubSequence(path: "/api/v2/admin/backups", responses: [
            MockHTTPResponse(data: Data(#"{"type":"about:blank","title":"Conflict","status":409,"detail":"locked"}"#.utf8), status: 409, headers: ["Content-Type": "application/problem+json"]),
        ])

        let done = await model.backUpNow(client: http.client)

        XCTAssertFalse(done)
        XCTAssertEqual(model.actionErrorMessage, "locked")
    }

    func testDeleteSendsDELETEForOneEncodedID() async throws {
        try stubBackupList()
        http.state.stub(path: "/api/v2/admin/backups/a b", data: Data(), status: 204)
        let model = SectionModel<BackupsPage>.backups()
        await model.load(client: http.client)

        _ = await model.deleteBackup(id: "a b", client: http.client)

        let url = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/backups/a b").first?.url)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/api/v2/admin/backups/a%20b")
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/backups/a b").first?.httpMethod, "DELETE")
    }

    // MARK: Settings editor

    private let effectivePath = "/api/v2/admin/settings/effective"

    private func effective(_ enabled: String = "true", _ time: String = "04:00", _ keep: String = "7", etag: String? = "\"e1\"") -> MockHTTPResponse {
        MockHTTPResponse(
            data: Data(#"{"backup.enabled":"\#(enabled)","backup.time":"\#(time)","backup.keep":"\#(keep)","other":"x"}"#.utf8),
            status: 200, headers: etag.map { ["ETag": $0] } ?? [:]
        )
    }

    private func receipt(_ key: String, _ value: String) -> MockHTTPResponse {
        MockHTTPResponse(json: ["key": key, "value": value])
    }

    private func openedEditor() async -> BackupSettingsEditor {
        http.state.stubSequence(path: effectivePath, responses: [effective(), effective(etag: "\"e2\""), effective(etag: "\"e3\"")])
        let editor = BackupSettingsEditor()
        await editor.open(client: http.client)
        return editor
    }

    func testOpenFillsTheThreeValuesFromTheEffectiveSettings() async {
        let editor = await openedEditor()
        XCTAssertTrue(editor.isEnabled)
        XCTAssertEqual(editor.timeText, "04:00")
        XCTAssertEqual(editor.keep, 7)
        XCTAssertFalse(editor.canSave)
        XCTAssertNil(editor.errorMessage)
    }

    func testMissingETagRefusesTheEdit() async {
        http.state.stubSequence(path: effectivePath, responses: [effective(etag: nil)])
        let editor = BackupSettingsEditor()

        await editor.open(client: http.client)

        XCTAssertFalse(editor.canSave)
        XCTAssertNotNil(editor.errorMessage)
        XCTAssertFalse(editor.hasValues)
    }

    func testOnlyChangedKeysAreWrittenEachWithItsKeyAndTheOpenETag() async throws {
        let editor = await openedEditor()
        http.state.stub(path: "/api/v2/admin/settings/backup.time", response: receipt("backup.time", "05:30"))
        editor.minutes = 5 * 60 + 30

        XCTAssertTrue(editor.canSave)
        let saved = await editor.save(client: http.client)

        XCTAssertTrue(saved)
        let puts = http.state.requests(path: "/api/v2/admin/settings/backup.time").filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(puts.count, 1)
        XCTAssertEqual(puts.first?.value(forHTTPHeaderField: "If-Match"), "\"e1\"")
        let body = try XCTUnwrap(http.state.body(path: "/api/v2/admin/settings/backup.time", requestIndex: 0))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["value": "05:30"])
        XCTAssertTrue(http.state.requests(path: "/api/v2/admin/settings/backup.keep").isEmpty)
    }

    func testSeveralChangesAreWrittenInOrderWithAFreshVersionForEach() async throws {
        let editor = await openedEditor()
        http.state.stub(path: "/api/v2/admin/settings/backup.enabled", response: receipt("backup.enabled", "false"))
        http.state.stub(path: "/api/v2/admin/settings/backup.keep", response: receipt("backup.keep", "14"))
        editor.isEnabled = false
        editor.keep = 14

        let saved = await editor.save(client: http.client)

        XCTAssertTrue(saved)
        let enabledPut = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/settings/backup.enabled").first)
        let keepPut = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/settings/backup.keep").first)
        XCTAssertEqual(enabledPut.value(forHTTPHeaderField: "If-Match"), "\"e1\"")
        XCTAssertEqual(keepPut.value(forHTTPHeaderField: "If-Match"), "\"e2\"", "the second write uses the version read after the first")
        let enabledBody = try XCTUnwrap(http.state.body(path: "/api/v2/admin/settings/backup.enabled", requestIndex: 0))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: enabledBody) as? [String: String], ["value": "false"])
    }

    func testAConflictStopsTheSaveKeepsTheEditAndSaysWhatToDo() async throws {
        let editor = await openedEditor()
        http.state.stub(path: "/api/v2/admin/settings/backup.time", response: MockHTTPResponse(
            data: Data(#"{"title":"Precondition Failed","status":412,"detail":"changed"}"#.utf8), status: 412,
            headers: ["Content-Type": "application/problem+json"]
        ))
        editor.minutes = 60

        let saved = await editor.save(client: http.client)

        XCTAssertFalse(saved)
        XCTAssertTrue(editor.hasConflict)
        XCTAssertEqual(editor.minutes, 60)
        XCTAssertEqual(editor.errorMessage, "These settings changed on the server after you opened them. Reload the current values, then make your change again.")
    }

    func testReloadingAfterAConflictTakesTheServerValues() async throws {
        let editor = await openedEditor()
        http.state.stub(path: "/api/v2/admin/settings/backup.time", response: MockHTTPResponse(
            data: Data(#"{"title":"Precondition Failed","status":412,"detail":"changed"}"#.utf8), status: 412,
            headers: ["Content-Type": "application/problem+json"]
        ))
        editor.minutes = 60
        _ = await editor.save(client: http.client)
        http.state.stubSequence(path: effectivePath, responses: [effective("true", "06:15", "9", etag: "\"e9\"")])

        await editor.open(client: http.client)

        XCTAssertFalse(editor.hasConflict)
        XCTAssertEqual(editor.timeText, "06:15")
        XCTAssertEqual(editor.keep, 9)
    }

    func testCopiesKeptStaysWithinWhatTheServerAccepts() {
        XCTAssertEqual(BackupSettingsEditor.keepRange, 1...60)
    }
}
