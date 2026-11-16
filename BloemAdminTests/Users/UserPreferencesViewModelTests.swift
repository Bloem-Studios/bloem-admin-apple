import XCTest
@testable import BloemAdmin

@MainActor
final class UserPreferencesViewModelTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let valuesPath = "/api/v2/admin/users/42/settings/values"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func row(_ key: String, _ scope: String, _ value: Any, profile: String? = "p1", device: String? = nil, library: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["key": key, "scope": scope, "value": value, "revision": 1]
        if let profile { row["profile_id"] = profile }
        if let device { row["device_id"] = device }
        if let library { row["library_id"] = library }
        return row
    }

    private let contract: [String: Any] = [
        "revision": 1,
        "definitions": [
            ["key": "playback.autoplay", "persistence": "remote", "allowed_scopes": ["profile", "profile_device", "profile_library"], "category": "playback", "label": "Autoplay",
             "default_value": true, "value_schema": ["type": "boolean"]],
            ["key": "playback.quality", "persistence": "remote", "allowed_scopes": ["profile", "profile_device"], "category": "playback", "label": "Quality",
             "default_value": "auto", "value_schema": ["type": "enum", "values": [["value": "auto", "label": "Auto"], ["value": "high", "label": "High"]]]],
            ["key": "ui.rows", "persistence": "remote", "allowed_scopes": ["profile"], "category": "ui", "label": "Rows",
             "value_schema": ["type": "integer", "minimum": 1, "maximum": 5]],
        ],
    ]

    private func stubReads(rows: [[String: Any]], contract: Bool = true) {
        http.state.stub(path: valuesPath, json: UserFixtures.page(rows))
        http.state.stub(path: "/api/v2/admin/users/42/profiles", json: UserFixtures.page([["id": "p1", "name": "Alex"]]))
        http.state.stub(path: "/api/v2/admin/users/42/devices", json: UserFixtures.page([]))
        http.state.stub(path: "/api/v2/libraries", json: UserFixtures.page([["id": "7", "name": "Movies"]]))
        if contract {
            http.state.stub(path: "/api/v2/settings/contract", json: self.contract)
        } else {
            http.state.stub(path: "/api/v2/settings/contract", data: Data(), status: 500)
        }
    }

    private func makeModel(serverName: String? = nil, devices: Bool = true) -> UserPreferencesViewModel {
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)
        let admin = UserAdmin(viewModel: UsersViewModel(serverName: serverName), client: client, sessionState: nil)
        return UserPreferencesViewModel(admin: admin, userID: "42", devicesAvailable: devices)
    }

    func testLoadingReadsTheSettingsWithTheNamesAndTheContractAndDevicesOnlyWhenOffered() async {
        stubReads(rows: [row("playback.autoplay", "profile", false)])
        let model = makeModel(devices: false)

        await model.load()

        XCTAssertEqual(model.levels.map(\.kind), [.profile])
        XCTAssertEqual(model.levels.first?.entries.map(\.key), ["playback.autoplay"])
        XCTAssertEqual(model.definition(for: "playback.autoplay")?.label, "Autoplay")
        XCTAssertTrue(http.state.requests(path: "/api/v2/admin/users/42/devices").isEmpty)
        XCTAssertFalse(http.state.requests(path: "/api/v2/settings/contract").isEmpty)
    }

    func testAnUnreadableContractLeavesEveryValueShownAndNoneEditable() async {
        stubReads(rows: [row("playback.autoplay", "profile", false)], contract: false)
        let model = makeModel()

        await model.load()

        XCTAssertNil(model.loadedDefinitions, "without the contract nothing can be edited truthfully")
        XCTAssertEqual(model.levels.first?.entries.count, 1)
        XCTAssertEqual(PreferenceLevels.editor(for: model.definition(for: "playback.autoplay")), .viewOnly)
    }

    func testUnreadableSettingsFailTheTabWithTheServersMessageAndAFailedReReadKeepsWhatIsShown() async {
        http.state.stubSequence(path: valuesPath, responses: [
            MockHTTPResponse(data: Data(#"{"error":"server_error","message":"Boom"}"#.utf8), status: 500),
            UserFixtures.response(UserFixtures.page([row("playback.autoplay", "profile", true)])),
            MockHTTPResponse(data: Data(#"{"error":"server_error","message":"Boom"}"#.utf8), status: 500),
        ])
        http.state.stub(path: "/api/v2/admin/users/42/profiles", json: UserFixtures.page([["id": "p1", "name": "Alex"]]))
        http.state.stub(path: "/api/v2/settings/contract", json: contract)
        let model = makeModel()

        await model.load()
        guard case .failed(let message) = model.state else { return XCTFail("expected a failure, got \(model.state)") }
        XCTAssertEqual(message, "Boom")

        await model.load()
        XCTAssertEqual(model.levels.first?.entries.count, 1)

        await model.load()
        XCTAssertEqual(model.levels.first?.entries.count, 1, "a failed re-read keeps what is shown")
    }

    func testChangingAValueWritesThatOneRowAndReadsTheSettingsAgain() async throws {
        stubReads(rows: [row("playback.autoplay", "profile_device", false, device: "d1")])
        let model = makeModel()
        await model.load()
        let entry = try XCTUnwrap(model.levels.flatMap(\.entries).first)
        http.state.stub(path: "\(valuesPath)/playback.autoplay", data: Data(), status: 200)

        let done = await model.set(key: entry.key, identity: entry.identity, value: .bool(true))

        XCTAssertTrue(done)
        let put = try XCTUnwrap(http.state.requests(path: "\(valuesPath)/playback.autoplay").first)
        XCTAssertEqual(put.httpMethod, "PUT")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(put.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }), ["scope": "profile_device", "profile_id": "p1", "device_id": "d1"])
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(http.state.body(path: "\(valuesPath)/playback.autoplay", requestIndex: 0))) as? [String: Any])
        XCTAssertEqual(sent["value"] as? Bool, true)
        XCTAssertEqual(http.state.requests(path: valuesPath).count, 2, "read again after the write")
    }

    func testAddingStartsAtWhatTheSettingReplacesAndSkipsWhatIsAlreadySet() async throws {
        stubReads(rows: [row("playback.autoplay", "profile", false), row("playback.quality", "profile_device", "high", device: "d1")])
        let model = makeModel()
        await model.load()
        let deviceLevel = try XCTUnwrap(model.levels.first { $0.kind == .device })
        http.state.stub(path: "\(valuesPath)/playback.autoplay", data: Data(), status: 200)
        http.state.stub(path: "\(valuesPath)/playback.quality", data: Data(), status: 200)

        let done = await model.add(to: deviceLevel, keys: ["playback.autoplay", "playback.quality"])

        XCTAssertTrue(done)
        XCTAssertEqual(http.state.requests(path: "\(valuesPath)/playback.quality").count, 0, "already set on the device")
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(http.state.body(path: "\(valuesPath)/playback.autoplay", requestIndex: 0))) as? [String: Any])
        XCTAssertEqual(sent["value"] as? Bool, false, "starts at the profile's value, so nothing changes until it is edited")
    }

    func testRemovingDeletesExactlyTheRowAndARefusedWriteIsShownAndStillReread() async throws {
        stubReads(rows: [row("playback.autoplay", "profile_library", false, library: "7")])
        let model = makeModel()
        await model.load()
        let entry = try XCTUnwrap(model.levels.flatMap(\.entries).first)
        http.state.stub(path: "\(valuesPath)/playback.autoplay", data: Data(#"{"error":"forbidden","message":"Not allowed"}"#.utf8), status: 403)

        let done = await model.remove(entry)

        XCTAssertFalse(done)
        XCTAssertEqual(model.errorMessage, "Not allowed")
        let request = try XCTUnwrap(http.state.requests(path: "\(valuesPath)/playback.autoplay").first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Set(query.map(\.name)), ["scope", "profile_id", "library_id"])
        XCTAssertEqual(http.state.requests(path: valuesPath).count, 2, "the list shows what the server has even after a refusal")
    }

    func testInAllServersAWriteGoesToThatServerOnlyAndAFailureNamesIt() async throws {
        let home = APIClient(baseURL: URL(string: "https://home.test")!, accessToken: "tok", session: http.session)
        http.state.stub(host: "home.test", path: valuesPath, data: try JSONSerialization.data(withJSONObject: UserFixtures.page([row("playback.autoplay", "profile", false)])))
        http.state.stub(host: "home.test", path: "\(valuesPath)/playback.autoplay", data: Data(#"{"error":"forbidden","message":"Not allowed"}"#.utf8), status: 403)
        let admin = UserAdmin(viewModel: UsersViewModel(serverName: "Home"), client: home, sessionState: nil)
        let model = UserPreferencesViewModel(admin: admin, userID: "42", devicesAvailable: false)
        await model.load()
        let entry = try XCTUnwrap(model.levels.flatMap(\.entries).first)

        let done = await model.set(key: entry.key, identity: entry.identity, value: .bool(true))

        XCTAssertFalse(done)
        XCTAssertEqual(model.errorMessage, "Home: Not allowed")
        XCTAssertTrue(http.state.requests(host: "example.test").isEmpty)
    }
}
