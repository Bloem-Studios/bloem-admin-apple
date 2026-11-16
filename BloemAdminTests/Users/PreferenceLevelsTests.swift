import XCTest
@testable import BloemAdmin

final class PreferenceLevelsTests: XCTestCase {
    private func entry(
        _ key: String, _ scope: String, _ value: JSONValue = .bool(true),
        profile: String? = nil, device: String? = nil, family: String? = nil, library: String? = nil, series: String? = nil
    ) -> UserSettingEntry {
        UserSettingEntry(key: key, scope: scope, value: value, profileID: profile, clientFamily: family, deviceID: device, libraryID: library, seriesID: series)
    }

    private func definition(_ json: String) throws -> SettingDefinition {
        try JSONDecoder().decode(SettingDefinition.self, from: Data(json.utf8))
    }

    private func device(_ id: String, name: String, profiles: [String]) throws -> UserDevice {
        let profileJSON = profiles.map { #"{"profile_id":"\#($0)","profile_name":"n","override_count":0,"last_seen_at":null}"# }.joined(separator: ",")
        let json = #"{"device_id":"\#(id)","device_name":"\#(name)","device_platform":"tv","last_seen_at":null,"last_updated":null,"override_count":0,"profiles":[\#(profileJSON)]}"#
        return try JSONDecoder.iso8601.decode(UserDevice.self, from: Data(json.utf8))
    }

    private let profiles = [UserProfile(id: "p1", name: "Alex"), UserProfile(id: "p2", name: "Kids")]

    // MARK: - Levels

    func testAnAccountWithNoSettingsStillListsEachProfilesAllDevicesLevel() {
        let groups = PreferenceLevels.build(entries: [], profiles: profiles, devices: [], libraryNames: [:])
        XCTAssertEqual(groups.map(\.profileName), ["Alex", "Kids"])
        XCTAssertEqual(groups.flatMap(\.levels).map(\.kind), [.profile, .profile])
        XCTAssertTrue(groups.flatMap(\.levels).allSatisfy { $0.entries.isEmpty })
    }

    func testAccountWideRowsGetTheirOwnGroupFirst() {
        let groups = PreferenceLevels.build(
            entries: [entry("a", "account"), entry("b", "profile", profile: "p1")],
            profiles: profiles, devices: [], libraryNames: [:]
        )
        XCTAssertEqual(groups.first?.key, "account")
        XCTAssertEqual(groups.first?.levels.first?.kind, .account)
        XCTAssertEqual(groups.first?.levels.first?.identity, SettingIdentity(scope: "account"))
        XCTAssertEqual(groups.dropFirst().first?.levels.first?.entries.map(\.key), ["b"])
    }

    func testAProfilesLevelsRunFromAllDevicesThroughDevicesAppFamiliesLibrariesAndSeries() throws {
        let entries = [
            entry("s1", "profile_series", profile: "p1", series: "99"),
            entry("l1", "profile_library", profile: "p1", library: "7"),
            entry("l2", "profile_library", profile: "p1", library: "3"),
            entry("c1", "profile_client", profile: "p1", family: "web"),
            entry("c2", "profile_client", profile: "p1", family: "tv"),
            entry("d1", "profile_device", profile: "p1", device: "dev-a"),
            entry("x", "profile", profile: "p1"),
        ]
        let groups = PreferenceLevels.build(
            entries: entries, profiles: [profiles[0]],
            devices: [try device("dev-a", name: "Living room", profiles: ["p1"])],
            libraryNames: ["7": "Movies", "3": "Anime"]
        )
        let levels = try XCTUnwrap(groups.first?.levels)
        XCTAssertEqual(levels.map(\.kind), [.profile, .device, .client, .client, .library, .library, .series])
        XCTAssertEqual(levels[1].deviceName, "Living room")
        XCTAssertEqual(levels[2].clientFamily, "tv", "app families follow tv, mobile, tablet, desktop, web")
        XCTAssertEqual(levels[3].clientFamily, "web")
        XCTAssertEqual(levels[4].libraryName, "Anime", "libraries are listed by name")
        XCTAssertEqual(levels[5].libraryName, "Movies")
        XCTAssertEqual(levels[6].identity, SettingIdentity(scope: "profile_series", profileID: "p1", seriesID: "99"))
    }

    func testADeviceTheProfileWasSeenOnIsListedEvenWithNoSettingsOneItWasNotSeenOnIsNot() throws {
        let groups = PreferenceLevels.build(
            entries: [], profiles: [profiles[0]],
            devices: [try device("seen", name: "Phone", profiles: ["p1"]), try device("other", name: "iPad", profiles: ["p2"])],
            libraryNames: [:]
        )
        XCTAssertEqual(groups.first?.levels.compactMap(\.deviceID), ["seen"])
    }

    func testRowsOfAProfileTheAccountNoLongerListsStillShowNamedByTheirID() {
        let groups = PreferenceLevels.build(
            entries: [entry("a", "profile", profile: "gone")], profiles: [profiles[0]], devices: [], libraryNames: [:]
        )
        XCTAssertEqual(groups.map(\.profileName), ["Alex", "gone"])
        XCTAssertEqual(groups.last?.levels.first?.entries.map(\.key), ["a"])
    }

    func testEntriesFollowTheContractsOrderThenTheKey() {
        let groups = PreferenceLevels.build(
            entries: [entry("b", "account"), entry("a", "account"), entry("z", "account")],
            profiles: [], devices: [], libraryNames: [:], order: ["z": 0, "b": 1]
        )
        XCTAssertEqual(groups.first?.levels.first?.entries.map(\.key), ["z", "b", "a"])
    }

    // MARK: - What a setting replaces

    func testASettingOnADeviceReplacesTheProfilesValueElseTheAppDefault() throws {
        let groups = PreferenceLevels.build(
            entries: [entry("autoplay", "profile", .bool(false), profile: "p1"), entry("autoplay", "profile_device", .bool(true), profile: "p1", device: "d")],
            profiles: [profiles[0]], devices: [], libraryNames: [:]
        )
        let levels = try XCTUnwrap(groups.first?.levels)
        let profileLevel = levels[0], deviceLevel = levels[1]
        let def = try definition(#"{"key":"autoplay","default_value":true,"value_schema":{"type":"boolean"}}"#)

        let onDevice = PreferenceLevels.replacedValue(level: deviceLevel, key: "autoplay", profileEntries: profileLevel.entries, definition: def)
        XCTAssertEqual(onDevice, ReplacedValue(profileName: "Alex", value: .bool(false)))

        let onProfile = PreferenceLevels.replacedValue(level: profileLevel, key: "autoplay", profileEntries: profileLevel.entries, definition: def)
        XCTAssertEqual(onProfile, ReplacedValue(profileName: nil, value: .bool(true)))

        let missing = PreferenceLevels.replacedValue(level: deviceLevel, key: "other", profileEntries: profileLevel.entries, definition: nil)
        XCTAssertEqual(missing, ReplacedValue(profileName: nil, value: nil))
    }

    func testOnlyRemoteCurrentSettingsForTheLevelsScopeThatAreNotSetThereCanBeAdded() throws {
        let level = PreferenceLevel(
            id: "profile.p1", kind: .profile, identity: SettingIdentity(scope: "profile", profileID: "p1"),
            profileID: "p1", profileName: "Alex", entries: [entry("have", "profile", profile: "p1")]
        )
        let definitions = [
            try definition(#"{"key":"have","persistence":"remote","allowed_scopes":["profile"]}"#),
            try definition(#"{"key":"add","persistence":"remote","allowed_scopes":["profile","account"]}"#),
            try definition(#"{"key":"local","persistence":"local","allowed_scopes":["profile"]}"#),
            try definition(#"{"key":"old","persistence":"remote","allowed_scopes":["profile"],"deprecated":true}"#),
            try definition(#"{"key":"device-only","persistence":"remote","allowed_scopes":["profile_device"]}"#),
        ]
        XCTAssertEqual(PreferenceLevels.addableSettings(level: level, definitions: definitions).map(\.key), ["add"])
    }

    // MARK: - Editors, parsing and wording

    func testTheContractsValueTypesPickTheEditor() throws {
        XCTAssertEqual(PreferenceLevels.editor(for: try definition(#"{"key":"k","value_schema":{"type":"boolean"}}"#)), .toggle)
        XCTAssertEqual(
            PreferenceLevels.editor(for: try definition(#"{"key":"k","value_schema":{"type":"integer","minimum":1,"maximum":9,"nullable":true}}"#)),
            .number(integer: true, minimum: 1, maximum: 9, nullable: true)
        )
        XCTAssertEqual(
            PreferenceLevels.editor(for: try definition(#"{"key":"k","value_schema":{"type":"number"}}"#)),
            .number(integer: false, minimum: nil, maximum: nil, nullable: false)
        )
        XCTAssertEqual(PreferenceLevels.editor(for: try definition(#"{"key":"k","value_schema":{"type":"language_tag","nullable":true}}"#)), .text(nullable: true))
        XCTAssertEqual(PreferenceLevels.editor(for: try definition(#"{"key":"k","value_schema":{"type":"object"}}"#)), .viewOnly)
        XCTAssertEqual(PreferenceLevels.editor(for: nil), .viewOnly)
    }

    func testADeprecatedChoiceIsOfferedOnlyWhileItIsTheStoredValue() throws {
        let def = try definition(#"{"key":"k","value_schema":{"type":"enum","values":[{"value":"a","label":"A"},{"value":"old","label":"Old","deprecated":true}]}}"#)
        guard case .choice(let fresh) = PreferenceLevels.editor(for: def, current: .string("a")) else { return XCTFail("expected a choice") }
        XCTAssertEqual(fresh.map(\.value), [.string("a")])
        guard case .choice(let keeping) = PreferenceLevels.editor(for: def, current: .string("old")) else { return XCTFail("expected a choice") }
        XCTAssertEqual(keeping.map(\.value), [.string("a"), .string("old")])
    }

    func testNumbersKeepTheirJSONTypeAndAreCheckedAgainstTheContractsRange() {
        func parse(_ text: String, integer: Bool = true, nullable: Bool = false) -> ParsedValue {
            PreferenceLevels.parseNumber(text, integer: integer, minimum: 1, maximum: 10, nullable: nullable)
        }
        XCTAssertEqual(parse("5"), .ok(.integer(5)))
        XCTAssertEqual(parse(" 7 "), .ok(.integer(7)))
        XCTAssertEqual(parse("2.5", integer: false), .ok(.number(2.5)))
        XCTAssertEqual(parse("2.5"), .notANumber, "an integer setting takes a whole number")
        XCTAssertEqual(parse("abc"), .notANumber)
        XCTAssertEqual(parse(""), .notANumber)
        XCTAssertEqual(parse("", nullable: true), .ok(.null))
        XCTAssertEqual(parse("0"), .outOfRange(minimum: 1, maximum: 10))
        XCTAssertEqual(parse("11"), .outOfRange(minimum: 1, maximum: 10))
        XCTAssertEqual(parse("inf", integer: false), .notANumber)
    }

    func testTextIsNullOnlyWhenEmptyAndNullable() {
        XCTAssertEqual(PreferenceLevels.parseText("", nullable: true), .null)
        XCTAssertEqual(PreferenceLevels.parseText("", nullable: false), .string(""))
        XCTAssertEqual(PreferenceLevels.parseText("en", nullable: true), .string("en"))
    }

    func testValuesAreShownAsTheContractWordsThem() throws {
        let def = try definition(#"{"key":"k","value_schema":{"type":"enum","values":[{"value":"hi","label":"High quality"}]}}"#)
        func shown(_ value: JSONValue?, _ definition: SettingDefinition? = nil) -> String {
            PreferenceLevels.valueText(definition: definition, value: value, on: "On", off: "Off", unset: "Not set")
        }
        XCTAssertEqual(shown(.bool(true)), "On")
        XCTAssertEqual(shown(.bool(false)), "Off")
        XCTAssertEqual(shown(.null), "Not set")
        XCTAssertEqual(shown(nil), "Not set")
        XCTAssertEqual(shown(.string("hi"), def), "High quality")
        XCTAssertEqual(shown(.string("zz"), def), "zz")
        XCTAssertEqual(shown(.integer(3)), "3")
        XCTAssertEqual(shown(.number(2.5)), "2.5")
        XCTAssertEqual(shown(.object(["a": .integer(1)])), #"{"a":1}"#)
    }

    func testACategoryTitleComesFromItsID() {
        XCTAssertEqual(PreferenceLevels.categoryTitle("playback"), "Playback")
        XCTAssertEqual(PreferenceLevels.categoryTitle("watch_party"), "Watch Party")
        XCTAssertEqual(PreferenceLevels.categoryTitle(""), "")
    }

    func testAStartingValueIsAlwaysOneTheSettingAccepts() throws {
        func start(_ json: String, replaced: JSONValue? = nil) throws -> JSONValue {
            PreferenceLevels.startingValue(replaced: ReplacedValue(profileName: nil, value: replaced), definition: try definition(json))
        }
        XCTAssertEqual(try start(#"{"key":"k","value_schema":{"type":"boolean"}}"#, replaced: .bool(true)), .bool(true), "what it replaces")
        XCTAssertEqual(try start(#"{"key":"k","value_schema":{"type":"boolean"}}"#), .bool(false))
        XCTAssertEqual(try start(#"{"key":"k","value_schema":{"type":"enum","values":[{"value":"old","deprecated":true},{"value":"a"}]}}"#), .string("a"))
        XCTAssertEqual(try start(#"{"key":"k","value_schema":{"type":"integer","minimum":2}}"#), .integer(2))
        XCTAssertEqual(try start(#"{"key":"k","value_schema":{"type":"integer"}}"#), .integer(0))
        XCTAssertEqual(try start(#"{"key":"k","value_schema":{"type":"number","minimum":0.5}}"#), .number(0.5))
        XCTAssertEqual(try start(#"{"key":"k","value_schema":{"type":"string"}}"#), .string(""))
        XCTAssertEqual(try start(#"{"key":"k","value_schema":{"type":"string","nullable":true}}"#), .null)
        XCTAssertEqual(try start(#"{"key":"k","value_schema":{"type":"object"}}"#), .null)
    }

    // MARK: - JSON

    func testAJSONValueKeepsItsTypeThroughDecodeAndEncode() throws {
        let source = #"{"a":1,"b":1.5,"c":true,"d":"x","e":null,"f":[1,"y"],"g":{"h":2}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        guard case .object(let object) = value else { return XCTFail("expected an object") }
        XCTAssertEqual(object["a"], .integer(1))
        XCTAssertEqual(object["b"], .number(1.5))
        XCTAssertEqual(object["c"], .bool(true))
        XCTAssertEqual(object["e"], .null)
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(again, value)
        XCTAssertEqual(String(data: try JSONEncoder().encode(JSONValue.integer(3)), encoding: .utf8), "3")
        XCTAssertEqual(String(data: try JSONEncoder().encode(JSONValue.bool(true)), encoding: .utf8), "true")
    }

    func testASettingsRowIsAddressedByItsFullIdentity() {
        XCTAssertEqual(
            SettingIdentity(scope: "profile_device", profileID: "p", deviceID: "d").query,
            ["scope": "profile_device", "profile_id": "p", "device_id": "d"]
        )
        XCTAssertEqual(SettingIdentity(scope: "account").query, ["scope": "account"])
    }
}
