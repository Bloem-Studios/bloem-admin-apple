import XCTest
@testable import BloemAdmin

final class SettingsCatalogueTests: XCTestCase {
    func testTheFieldAdminPagesExistInTheWebsOrder() {
        XCTAssertEqual(
            SettingsCatalogue.pages.map(\.id),
            ["general", "network-access", "sign-in", "playback", "logging", "email", "notifications", "downloads", "requests"]
        )
    }

    func testPageIdsAreTheWebsRouteSegments() {
        for id in SettingsCatalogue.pages.map(\.id) {
            XCTAssertNotNil(SettingsCatalogue.page(id: id))
        }
        XCTAssertEqual(SettingsCatalogue.page(id: "sign-in")?.titleText, "Sign-in")
        XCTAssertEqual(SettingsCatalogue.page(id: "network-access")?.titleText, "Network access")
    }

    func testNoKeyAppearsOnTwoPagesOrTwice() {
        let keys = SettingsCatalogue.pages.flatMap(\.keys)
        XCTAssertEqual(keys.count, Set(keys).count, "duplicate keys: \(Dictionary(grouping: keys, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
    }

    func testEveryKeyIsAnAdminSettingKeyShape() {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.")
        for key in SettingsCatalogue.pages.flatMap(\.keys) {
            XCTAssertTrue(key.unicodeScalars.allSatisfy(allowed.contains), key)
            XCTAssertFalse(key.hasPrefix(".") || key.hasSuffix("."), key)
        }
    }

    /// Keys the server registry defines under these exact names (server:internal/config/admin_settings.go,
    /// internal/playback/throttle.go); a typo here would write a key the server never reads.
    func testKeysTheWebNamesWithoutAPrefixAreKeptExactly() {
        let keys = Set(SettingsCatalogue.pages.flatMap(\.keys))
        XCTAssertTrue(keys.contains("allow_4k_transcode"))
        XCTAssertTrue(keys.contains("enable_transcode_throttle"))
        XCTAssertTrue(keys.contains("transcode_throttle_seconds"))
        XCTAssertTrue(keys.contains("server.log_level"))
        XCTAssertTrue(keys.contains("server.public_url"))
        XCTAssertTrue(keys.contains("playback.transcode_enabled"))
    }

    func testLoggingPageHoldsTheLogLevelWithTheServersFourLevels() throws {
        let spec = try XCTUnwrap(SettingsCatalogue.spec(forKey: "server.log_level")?.spec)
        guard case .choice(let choices) = spec.control else { return XCTFail("log level is a choice") }
        XCTAssertEqual(choices.map(\.value), ["debug", "info", "warn", "error"])
        XCTAssertEqual(SettingsCatalogue.spec(forKey: "server.log_level")?.page.id, "logging")
    }

    func testHardwareAccelerationOffersTheServersSixValues() throws {
        let spec = try XCTUnwrap(SettingsCatalogue.spec(forKey: "playback.hw_accel")?.spec)
        guard case .choice(let choices) = spec.control else { return XCTFail("a choice") }
        XCTAssertEqual(Set(choices.map(\.value)), ["auto", "qsv", "vaapi", "nvenc", "videotoolbox", "none"])
    }

    func testEncryptionOffersTheServersThreeValues() throws {
        let spec = try XCTUnwrap(SettingsCatalogue.spec(forKey: "email.smtp_security")?.spec)
        guard case .choice(let choices) = spec.control else { return XCTFail("a choice") }
        XCTAssertEqual(choices.map(\.value), ["starttls", "tls", "none"])
    }

    func testSecretsAreSecretControls() {
        XCTAssertEqual(SettingsCatalogue.spec(forKey: "email.smtp_password")?.spec.isSecret, true)
        XCTAssertEqual(SettingsCatalogue.spec(forKey: "redis.url")?.spec.isSecret, true)
        XCTAssertEqual(SettingsCatalogue.spec(forKey: "email.smtp_host")?.spec.isSecret, false)
    }

    func testEveryPageAndSettingHasWordsAndNoTrailingPeriod() {
        for page in SettingsCatalogue.pages {
            XCTAssertFalse(page.titleText.isEmpty)
            XCTAssertFalse(page.summaryText.isEmpty)
            XCTAssertFalse(page.titleText.hasSuffix("."), page.id)
            XCTAssertFalse(page.summaryText.hasSuffix("."), page.id)
            XCTAssertFalse(page.keywords.isEmpty, page.id)
            for spec in page.settings {
                XCTAssertFalse(spec.labelText.isEmpty, spec.key)
                XCTAssertFalse(spec.labelText.hasSuffix("."), spec.key)
                XCTAssertFalse(spec.helpText?.hasSuffix(".") ?? false, spec.key)
                XCTAssertFalse(spec.labelText.contains("!"), spec.key)
                XCTAssertFalse((spec.helpText ?? "").contains("!"), spec.key)
            }
        }
    }

    func testLabelsAreSentenceCase() {
        for spec in SettingsCatalogue.pages.flatMap(\.settings) {
            let words = spec.labelText.split(separator: " ").dropFirst()
            // Acronyms and product names may be capitalised; ordinary words after the first are lower case.
            for word in words where word.first?.isUppercase == true {
                XCTAssertTrue(
                    word.count <= 5 || ["Postgres", "Discord", "Continue", "Watching", "Sonarr", "Radarr"].contains(String(word)),
                    "\(spec.key): \(spec.labelText)"
                )
            }
        }
    }

    func testOtherSettingsAreEverythingTheCatalogueDoesNotName() {
        XCTAssertTrue(SettingsCatalogue.knownKeys.contains("server.log_level"))
        XCTAssertFalse(SettingsCatalogue.knownKeys.contains("scanner.workers"))
    }

    func testLabelForAnUnnamedKeyIsReadable() {
        XCTAssertEqual(SettingsCatalogue.label(forKey: "playback.hw_accel"), "Hardware acceleration")
        XCTAssertEqual(SettingsCatalogue.label(forKey: "scanner.file_removal_grace"), "Scanner file removal grace")
    }

    // MARK: Controls

    func testScaledNumbersShowGigabytesAndStoreBytes() throws {
        let control = try XCTUnwrap(SettingsCatalogue.spec(forKey: "download.artifact_max_bytes")?.spec.control)
        XCTAssertEqual(control.displayValue("50000000000"), "50")
        XCTAssertEqual(control.displayValue("1500000000"), "1.5")
        XCTAssertEqual(control.displayValue("0"), "0")
        XCTAssertEqual(control.storedValue(fromDisplay: "50"), "50000000000")
        XCTAssertEqual(control.storedValue(fromDisplay: "1.5"), "1500000000")
        XCTAssertEqual(control.storedValue(fromDisplay: ""), "")
        XCTAssertNil(control.storedValue(fromDisplay: "abc"))
    }

    func testPlainNumbersRoundTripAndAreChecked() throws {
        let control = try XCTUnwrap(SettingsCatalogue.spec(forKey: "download.artifact_disk_ceiling_percent")?.spec.control)
        XCTAssertEqual(control.displayValue("85"), "85")
        XCTAssertEqual(control.storedValue(fromDisplay: " 85 "), "85")
        XCTAssertNil(control.storedValue(fromDisplay: "8.5"))
        XCTAssertNil(control.problem(with: "85"))
        XCTAssertNil(control.problem(with: ""))
        XCTAssertEqual(control.problem(with: "49"), "Use 50 or more")
        XCTAssertEqual(control.problem(with: "96"), "Use 95 or less")
        XCTAssertEqual(control.problem(with: "x"), "Use a whole number")
    }
}
