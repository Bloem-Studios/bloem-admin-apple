import Security
import XCTest
@testable import BloemAdmin

/// The registration the extension reads while the phone is locked: where it is kept, and how.
final class PushRegistrationStoreTests: XCTestCase {
    private let group = "TEAM123456.com.bloemstudios.admin.shared"

    private func store(_ keychain: FakePushKeychain) -> KeychainPushRegistrationStore {
        KeychainPushRegistrationStore(accessGroup: group, security: keychain.client)
    }

    func testARegistrationRoundTrips() throws {
        let keychain = FakePushKeychain()
        let subject = store(keychain)
        let saved = PushRegistration.fixture(server: "home", device: "dev1")
        try subject.save(saved)
        try subject.save(PushRegistration.fixture(server: "lab", device: "dev2"))

        guard case .found(let all) = subject.load() else { return XCTFail("locked") }
        XCTAssertEqual(all.map(\.serverID), ["home", "lab"])
        XCTAssertEqual(all.first, saved)
        XCTAssertEqual(subject.registration(deviceID: "dev2")?.serverID, "lab")
        XCTAssertEqual(subject.registration(serverID: "home")?.deviceID, "dev1")
        XCTAssertNil(subject.registration(deviceID: "nobody"))
    }

    func testSavingAgainUpdatesTheSameItem() throws {
        let keychain = FakePushKeychain()
        let subject = store(keychain)
        try subject.save(PushRegistration.fixture(device: "dev1", token: "bad_old"))
        try subject.save(PushRegistration.fixture(device: "dev1", token: "bad_new"))

        XCTAssertEqual(keychain.stored.count, 1)
        XCTAssertEqual(subject.registration(serverID: "home")?.displayToken, "bad_new")
    }

    func testItIsKeptInTheSharedGroupReadableAfterFirstUnlockOnThisDeviceOnly() throws {
        let keychain = FakePushKeychain()
        try store(keychain).save(.fixture())

        let add = try XCTUnwrap(keychain.queries.last)
        XCTAssertEqual(add[kSecAttrAccessGroup as String] as? String, group)
        XCTAssertEqual(add[kSecAttrService as String] as? String, PushKeychain.service)
        XCTAssertEqual(add[kSecAttrAccount as String] as? String, "home")
        XCTAssertEqual(add[kSecClass as String] as? String, kSecClassGenericPassword as String)
        // The extension runs while the phone is locked, so this is the one item that is not WhenUnlocked.
        XCTAssertEqual(add[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testTheServiceIsNotTheWidgetsSignInMirror() {
        XCTAssertNotEqual(PushKeychain.service, SharedKeychain.service)
        XCTAssertEqual(PushKeychain.groupSuffix, SharedKeychain.groupSuffix, "one shared group, two services")
    }

    func testAPhoneThatHasNotBeenUnlockedYetIsLockedNotEmpty() throws {
        let keychain = FakePushKeychain()
        let subject = store(keychain)
        try subject.save(.fixture())
        keychain.readStatus = errSecInteractionNotAllowed

        XCTAssertEqual(subject.load(), .locked)
        XCTAssertNil(subject.registration(deviceID: "dev1"))
    }

    func testNothingSavedIsEmpty() {
        XCTAssertEqual(store(FakePushKeychain()).load(), .found([]))
    }

    func testRemovingOneServerLeavesTheOthers() throws {
        let keychain = FakePushKeychain()
        let subject = store(keychain)
        try subject.save(.fixture(server: "home", device: "dev1"))
        try subject.save(.fixture(server: "lab", device: "dev2"))
        subject.remove(serverID: "home")

        guard case .found(let all) = subject.load() else { return XCTFail("locked") }
        XCTAssertEqual(all.map(\.serverID), ["lab"])
    }

    func testAnItemFromAnotherVersionOrNotARegistrationIsSkipped() throws {
        let keychain = FakePushKeychain()
        let subject = store(keychain)
        try subject.save(.fixture(server: "home", device: "dev1"))
        keychain.put(Data("not json".utf8), account: "junk")
        var future = PushRegistration.fixture(server: "lab", device: "dev2")
        future.version = PushRegistration.currentVersion + 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        keychain.put(try encoder.encode(future), account: "lab")

        guard case .found(let all) = subject.load() else { return XCTFail("locked") }
        XCTAssertEqual(all.map(\.serverID), ["home"])
    }

    func testTheTokenNeverReachesALog() {
        let registration = PushRegistration.fixture(token: "bad_SECRET")
        XCTAssertFalse(String(reflecting: registration).contains("bad_SECRET"))
        XCTAssertFalse("\(registration)".contains("bad_SECRET"))
        XCTAssertFalse(String(describing: registration).contains("bad_SECRET"))
    }

    func testTheSharedSettingsFileDefaultsToTheMostPrivateChoice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("push-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePushSharedSettingsStore(directory: directory)

        XCTAssertFalse(store.load().showDetailsOnLockScreen, "missing means private")
        try store.save(PushSharedSettings(showDetailsOnLockScreen: true))
        XCTAssertTrue(store.load().showDetailsOnLockScreen)
        try Data("{".utf8).write(to: directory.appendingPathComponent(FilePushSharedSettingsStore.fileName))
        XCTAssertFalse(store.load().showDetailsOnLockScreen, "unreadable means private")
        try Data(#"{"version":99,"showDetailsOnLockScreen":true}"#.utf8).write(to: directory.appendingPathComponent(FilePushSharedSettingsStore.fileName))
        XCTAssertFalse(store.load().showDetailsOnLockScreen, "another version means private")
    }

    func testTheMirrorFollowsTheSetting() throws {
        let store = FakePushSettings(showsDetails: false)
        PushSettingsMirror.sync(showsDetails: true, store: store)
        XCTAssertTrue(store.load().showDetailsOnLockScreen)
        PushSettingsMirror.sync(showsDetails: false, store: store)
        XCTAssertFalse(store.load().showDetailsOnLockScreen)
    }
}
