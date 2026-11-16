import XCTest
@testable import BloemAdmin

final class SettingsSearchTests: XCTestCase {
    private func ids(_ query: String, other: [String] = []) -> [String] {
        SettingsSearch.results(for: query, otherKeys: other).map(\.id)
    }

    func testABlankQueryFindsNothing() {
        XCTAssertTrue(ids("").isEmpty)
        XCTAssertTrue(ids("   ").isEmpty)
    }

    func testFindsAnIndividualSettingByItsLabel() {
        XCTAssertTrue(ids("log level").contains("setting:logging:server.log_level"))
    }

    func testFindsASettingByTheWebsWordsNotOnlyItsLabel() {
        // "ssrf" and "opa" are the web's page words; "forgot password" is a web word of a setting's page.
        XCTAssertTrue(ids("forgot password").contains("setting:sign-in:password_reset.self_service_enabled"))
        XCTAssertTrue(ids("multicast").contains("setting:general:server.lan_discovery"))
    }

    func testFindsASettingByItsKey() {
        XCTAssertTrue(ids("smtp_host").contains("setting:email:email.smtp_host"))
        XCTAssertTrue(ids("transcode_throttle").contains("setting:playback:transcode_throttle_seconds"))
    }

    func testAPageIsFoundByItsNameAndByItsWords() {
        XCTAssertTrue(ids("playback").contains("page:playback"))
        XCTAssertTrue(ids("tailscale").contains("page:network-access"))
        XCTAssertTrue(ids("radarr").contains("page:requests"))
    }

    func testPagesComeBeforeSettings() {
        let found = SettingsSearch.results(for: "email")
        let firstSetting = found.firstIndex { if case .setting = $0 { true } else { false } }
        let lastPage = found.lastIndex { if case .page = $0 { true } else { false } }
        XCTAssertNotNil(firstSetting)
        XCTAssertNotNil(lastPage)
        XCTAssertLessThan(lastPage!, firstSetting!)
    }

    func testEveryTokenMustMatch() {
        XCTAssertTrue(ids("public url").contains("setting:general:server.public_url"))
        XCTAssertFalse(ids("public zebra").contains("setting:general:server.public_url"))
    }

    func testShortTokensMatchWordStartsOnly() {
        // "url" starts "url" but sits inside no other word's start; a 3-letter token must not match mid-word.
        XCTAssertFalse(ids("ubl").contains("setting:general:server.public_url"))
    }

    func testAccentsAndCaseAreIgnored() {
        XCTAssertTrue(ids("LOG LEVEL").contains("setting:logging:server.log_level"))
    }

    func testStoredKeysTheCatalogueDoesNotNameAreFoundByKey() {
        XCTAssertEqual(ids("scanner workers", other: ["scanner.workers", "matcher.workers"]), ["other:scanner.workers"])
    }
}
