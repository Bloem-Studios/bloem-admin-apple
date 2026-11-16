import Security
import SwiftUI
import XCTest
@testable import BloemAdmin

/// Where a tap on a widget goes, and how the sign-in reaches the widget.
final class WidgetLinksAndMirrorTests: XCTestCase {
    // MARK: Deep links

    func testEveryPageAWidgetOpensIsInTheAppsMenu() {
        let menu = Set(AdminDestination.singleServer(tenantsVisible: true, supportAccessVisible: true).map(\.id))
        for page in [DeepLinkPage.nowPlaying, DeepLinkPage.requests, DeepLinkPage.libraries, DeepLinkPage.nodes, DeepLinkPage.dashboard, "system.backups"] {
            XCTAssertTrue(menu.contains(page), "\(page) is not a menu page")
        }
    }

    func testAWidgetLinkOpensTheServerPageOrAllServers() {
        XCTAssertEqual(WidgetLink.page(DeepLinkPage.requests, serverID: nil).absoluteString, "bloemadmin://all/work.requests")
        XCTAssertEqual(WidgetLink.page(DeepLinkPage.nowPlaying, serverID: "abc-1").absoluteString, "bloemadmin://server/abc-1/live.streams")
        XCTAssertEqual(WidgetLink.page(DeepLinkPage.libraries, serverID: "abc-1").absoluteString, "bloemadmin://server/abc-1/content.libraries")
        XCTAssertEqual(WidgetLink.page(DeepLinkPage.nodes, serverID: "abc-1").absoluteString, "bloemadmin://server/abc-1/playback.nodes")
    }

    func testEveryWidgetLinkIsOneTheAppAccepts() throws {
        for page in [DeepLinkPage.nowPlaying, DeepLinkPage.requests, DeepLinkPage.libraries, DeepLinkPage.nodes] {
            for serverID in [nil, "home", "0f8fad5b-d9cb-469f-a165-70867728950e"] {
                let url = WidgetLink.page(page, serverID: serverID)
                let route = try XCTUnwrap(DeepLinkRoute(url: url), url.absoluteString)
                XCTAssertEqual(route.pageID, page)
                XCTAssertEqual(route.target, serverID.map { .server($0) } ?? .allServers)
            }
        }
    }

    func testEachWidgetOpensItsOwnPageForTheServerItShows() {
        let entry = WidgetSamples.entry(serverID: "home")
        XCTAssertEqual(entry.statusModel.link.absoluteString, "bloemadmin://server/home/live.streams")
        XCTAssertEqual(entry.streams.serverID, "home")
        XCTAssertEqual(entry.requests.serverID, "home")
        let all = WidgetSamples.entry()
        XCTAssertEqual(all.statusModel.link.absoluteString, "bloemadmin://all/live.streams")
        XCTAssertNil(all.requests.serverID)
    }

    func testEachRowOpensTheServerOfItsOwnItem() {
        let request = WidgetSamples.requests[0]
        XCTAssertEqual(WidgetLink.page(DeepLinkPage.requests, serverID: request.serverID).absoluteString, "bloemadmin://server/home/work.requests")
        XCTAssertEqual(WidgetLink.page(DeepLinkPage.nowPlaying, serverID: WidgetSamples.streams[0].serverID).absoluteString, "bloemadmin://server/home/live.streams")
    }

    func testTheLiveActivityOpensLibrariesOrBackupsOnItsServer() {
        let scan = AdminJobActivityAttributes(kind: .libraryScan, serverID: "home", serverName: "Home", startedAt: Date())
        let backup = AdminJobActivityAttributes(kind: .backup, serverID: "home", serverName: "Home", startedAt: Date())
        XCTAssertEqual(scan.link.absoluteString, "bloemadmin://server/home/content.libraries")
        XCTAssertEqual(backup.link.absoluteString, "bloemadmin://server/home/system.backups")
        XCTAssertNotNil(DeepLinkRoute(url: scan.link))
        XCTAssertNotNil(DeepLinkRoute(url: backup.link))
    }

    func testTheRequestsControlsCountIsTheStoredTotalOtherwiseTheAppsSnapshot() {
        var cache = WidgetDataCache()
        cache.requests["a"] = ServerFeed(serverID: "a", serverName: "A", condition: .current, items: [], total: 2, asOf: WidgetSamples.now)
        cache.requests["b"] = ServerFeed(serverID: "b", serverName: "B", condition: .current, items: [], total: 3, asOf: WidgetSamples.now)
        XCTAssertEqual(RequestsWaitingCount.current(cache: cache, snapshot: nil, now: WidgetSamples.now), 5)
        XCTAssertEqual(RequestsWaitingCount.current(cache: WidgetDataCache(), snapshot: WidgetSamples.snapshot, now: WidgetSamples.now), 4)
        XCTAssertEqual(RequestsWaitingCount.current(cache: nil, snapshot: nil, now: WidgetSamples.now), 0)
        XCTAssertEqual(RequestsWaitingCount.text(0), "No requests waiting")
        XCTAssertEqual(RequestsWaitingCount.text(4), "4 requests waiting")
    }

    // MARK: The keychain mirror

    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        var items: [String: Data] = [:]
        var queries: [[String: Any]] = []
        var addStatus: OSStatus = errSecSuccess
        var readStatus: OSStatus = errSecSuccess

        var client: SecurityClient {
            SecurityClient(
                copyMatching: { [self] query, result in
                    lock.withLock {
                        let q = query as! [String: Any]
                        queries.append(q)
                        if readStatus != errSecSuccess { return readStatus }
                        guard let data = items[q[kSecAttrAccount as String] as! String] else { return errSecItemNotFound }
                        result?.pointee = data as CFData
                        return errSecSuccess
                    }
                },
                update: { [self] query, attributes in
                    lock.withLock {
                        let q = query as! [String: Any]
                        queries.append(q)
                        let id = q[kSecAttrAccount as String] as! String
                        guard items[id] != nil else { return errSecItemNotFound }
                        items[id] = (attributes as! [String: Any])[kSecValueData as String] as? Data
                        return errSecSuccess
                    }
                },
                add: { [self] query, _ in
                    lock.withLock {
                        let q = query as! [String: Any]
                        queries.append(q)
                        if addStatus != errSecSuccess { return addStatus }
                        items[q[kSecAttrAccount as String] as! String] = q[kSecValueData as String] as? Data
                        return errSecSuccess
                    }
                },
                delete: { [self] query in
                    lock.withLock {
                        let q = query as! [String: Any]
                        items[q[kSecAttrAccount as String] as! String] = nil
                        return errSecSuccess
                    }
                }
            )
        }
    }

    func testTheMirrorUsesItsOwnServiceAndGroupAndTheSameProtectionAsTheAppsStore() throws {
        let keychain = FakeKeychain()
        let store = KeychainSharedCredentialStore(accessGroup: "TEAM.com.bloemstudios.admin.shared", security: keychain.client)
        let credential = SharedCredential(accessToken: "a", refreshToken: "r", updatedAt: Date(timeIntervalSince1970: 100), source: .app)
        try store.write(credential, serverID: "home")
        let add = try XCTUnwrap(keychain.queries.last)
        XCTAssertEqual(add[kSecAttrService as String] as? String, SharedKeychain.service)
        XCTAssertNotEqual(SharedKeychain.service, KeychainCredentialStore.service, "the mirror never overwrites the app's own item")
        XCTAssertEqual(add[kSecAttrAccessGroup as String] as? String, "TEAM.com.bloemstudios.admin.shared")
        XCTAssertEqual(add[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(store.read(serverID: "home"), .found(credential))
        XCTAssertEqual(store.read(serverID: "other"), .missing)
    }

    func testAWriteUpdatesAnExistingItemInsteadOfAddingASecond() throws {
        let keychain = FakeKeychain()
        let store = KeychainSharedCredentialStore(accessGroup: "g", security: keychain.client)
        try store.write(SharedCredential(accessToken: "a", refreshToken: nil, updatedAt: Date(), source: .app), serverID: "home")
        try store.write(SharedCredential(accessToken: "b", refreshToken: nil, updatedAt: Date(), source: .widget), serverID: "home")
        guard case .found(let read) = store.read(serverID: "home") else { return XCTFail("missing") }
        XCTAssertEqual(read.accessToken, "b")
        XCTAssertEqual(read.source, .widget)
        XCTAssertEqual(keychain.items.count, 1)
    }

    func testALockedPhoneReadsAsLockedAndAMissingEntitlementThrowsOnWrite() {
        let keychain = FakeKeychain()
        let store = KeychainSharedCredentialStore(accessGroup: "g", security: keychain.client)
        keychain.readStatus = errSecInteractionNotAllowed
        XCTAssertEqual(store.read(serverID: "home"), .locked)
        keychain.addStatus = errSecMissingEntitlement
        XCTAssertThrowsError(try store.write(SharedCredential(accessToken: "a", refreshToken: nil, updatedAt: Date(), source: .app), serverID: "home"))
    }

    func testTheGroupIsTheTeamPrefixPlusTheSharedName() {
        XCTAssertEqual(SharedKeychain.accessGroup(bundle: Bundle(for: WidgetLinksAndMirrorTests.self)).hasSuffix("com.bloemstudios.admin.shared"), true)
    }

    // MARK: The app's side

    private final class MemoryMirror: SharedCredentialStoring, @unchecked Sendable {
        private let lock = NSLock()
        var items: [String: SharedCredential] = [:]
        func read(serverID: String) -> SharedCredentialRead { lock.withLock { items[serverID].map(SharedCredentialRead.found) ?? .missing } }
        func write(_ credential: SharedCredential, serverID: String) throws { lock.withLock { items[serverID] = credential } }
        func delete(serverID: String) { lock.withLock { items[serverID] = nil } }
    }

    @MainActor
    private func store(mirror: MemoryMirror) -> (ServerStore, InMemoryCredentialStore) {
        let credentials = InMemoryCredentialStore()
        let store = ServerStore(
            metadataStore: InMemoryServerMetadataStore(), credentialStore: credentials,
            mirror: WidgetCredentialMirror(store: mirror, now: { Date(timeIntervalSince1970: 500) })
        )
        return (store, credentials)
    }

    @MainActor
    func testSigningInPublishesTheTokensToTheMirror() throws {
        let mirror = MemoryMirror()
        let (store, _) = store(mirror: mirror)
        try store.addServer(.fixture, credentials: .fixture)
        let shared = try XCTUnwrap(mirror.items[AdminServer.fixture.id])
        XCTAssertEqual(shared.accessToken, "access-1")
        XCTAssertEqual(shared.refreshToken, "refresh-1")
        XCTAssertEqual(shared.source, .app)
    }

    @MainActor
    func testARefreshInTheAppUpdatesTheMirrorAndSigningOutOrRemovingClearsIt() throws {
        let mirror = MemoryMirror()
        let (store, _) = store(mirror: mirror)
        try store.addServer(.fixture, credentials: .fixture)
        try store.updateCredentials(.rotated, forServerID: AdminServer.fixture.id)
        XCTAssertEqual(mirror.items[AdminServer.fixture.id]?.accessToken, "access-2")
        try store.signOut(AdminServer.fixture.id)
        XCTAssertNil(mirror.items[AdminServer.fixture.id])
        try store.updateCredentials(.fixture, forServerID: AdminServer.fixture.id)
        XCTAssertNotNil(mirror.items[AdminServer.fixture.id])
        try store.removeServer(AdminServer.fixture.id)
        XCTAssertNil(mirror.items[AdminServer.fixture.id])
    }

    @MainActor
    func testTheAppTakesBackTokensTheWidgetRotatedAndMarksThemAsItsOwn() throws {
        let mirror = MemoryMirror()
        let (store, credentials) = store(mirror: mirror)
        try store.addServer(.fixture, credentials: .fixture)
        mirror.items[AdminServer.fixture.id] = SharedCredential(
            accessToken: "widget-access", refreshToken: "widget-refresh", updatedAt: Date(), source: .widget
        )
        XCTAssertTrue(store.adoptWidgetRotation(for: AdminServer.fixture.id))
        XCTAssertEqual(try credentials.credentials(for: AdminServer.fixture.id)?.refreshToken, "widget-refresh")
        XCTAssertEqual(store.refreshToken(for: AdminServer.fixture.id), "widget-refresh", "the app refreshes with the newest token")
        XCTAssertEqual(mirror.items[AdminServer.fixture.id]?.source, .app)
        XCTAssertFalse(store.adoptWidgetRotation(for: AdminServer.fixture.id), "once")
    }

    @MainActor
    func testSyncingBringsAnOlderInstallsSignInIntoTheMirror() throws {
        let mirror = MemoryMirror()
        let (store, credentials) = store(mirror: mirror)
        try store.addServer(.fixture, credentials: .fixture)
        mirror.items = [:]
        _ = credentials
        store.syncWidgetCredentials()
        XCTAssertEqual(mirror.items[AdminServer.fixture.id]?.accessToken, "access-1")
    }

    @MainActor
    func testWithoutAMirrorNothingChanges() throws {
        let store = makeIsolatedServerStore()
        try store.addServer(.fixture, credentials: .fixture)
        XCTAssertFalse(store.adoptWidgetRotation(for: AdminServer.fixture.id))
        store.syncWidgetCredentials()
        XCTAssertEqual(store.accessToken(for: AdminServer.fixture.id), "access-1")
    }

    // MARK: The lock

    func testOnlyOneHolderOfTheRefreshLockAtATime() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let lock = CredentialRefreshLock(fileURL: url)
        let first = await lock.acquire(timeout: .seconds(1))
        XCTAssertTrue(first.isLocked)
        let second = await lock.acquire(timeout: .milliseconds(300))
        XCTAssertFalse(second.isLocked, "the second waits, then goes on without the lock instead of hanging")
        first.release()
        first.release()
        let third = await lock.acquire(timeout: .seconds(1))
        XCTAssertTrue(third.isLocked)
        third.release()
        second.release()
    }

    func testWithoutAContainerThereIsNoLockAndNoWait() async {
        let held = await CredentialRefreshLock(fileURL: nil).acquire()
        XCTAssertFalse(held.isLocked)
    }

    // MARK: The settings

    func testTheSettingsSyncWritesTheDetailsChoiceAndTheAppearanceOnlyWhenTheyChange() throws {
        let suite = "widget-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        final class Store: WidgetSettingsStoring, @unchecked Sendable {
            var settings = WidgetSettings()
            var saves = 0
            func load() -> WidgetSettings { settings }
            func save(_ settings: WidgetSettings) throws { self.settings = settings; saves += 1 }
        }
        final class Reloader: WidgetTimelineReloading, @unchecked Sendable {
            var count = 0
            func reloadAll() { count += 1 }
        }
        let store = Store()
        let reloader = Reloader()
        WidgetSettingsSync.write(defaults: defaults, store: store, reloader: reloader)
        XCTAssertEqual(store.saves, 0, "the defaults are what the widgets assume already")
        AlertPreferences(defaults: defaults).showsDetails = true
        defaults.set("dark", forKey: AppearancePreference.storageKey)
        WidgetSettingsSync.write(defaults: defaults, store: store, reloader: reloader)
        XCTAssertEqual(store.settings, WidgetSettings(showDetailsOnLockScreen: true, appearance: "dark"))
        XCTAssertEqual(reloader.count, 1)
        WidgetSettingsSync.write(defaults: defaults, store: store, reloader: reloader)
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(reloader.count, 1)
    }
}
