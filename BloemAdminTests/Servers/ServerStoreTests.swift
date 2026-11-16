import XCTest
@testable import BloemAdmin

private final class RecordingResetStore: ServerMetadataStoring, CredentialStoring, @unchecked Sendable {
    enum ResetError: Error, Equatable {
        case credentialDeletion(String)
    }

    enum Event: Equatable {
        case loadServers
        case saveServers([AdminServer])
        case deleteCredentials(String)
    }

    private let lock = NSLock()
    private var storedServers: [AdminServer]
    private var storedCredentials: [String: ServerCredentials]
    private let failingDeletionIDs: Set<String>
    private(set) var events: [Event] = []

    init(
        servers: [AdminServer],
        credentials: ServerCredentials,
        failingDeletionIDs: Set<String> = []
    ) {
        storedServers = servers
        storedCredentials = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, credentials) })
        self.failingDeletionIDs = failingDeletionIDs
    }

    func loadServers() throws -> [AdminServer] {
        lock.withLock {
            events.append(.loadServers)
            return storedServers
        }
    }

    func saveServers(_ servers: [AdminServer]) throws {
        lock.withLock {
            events.append(.saveServers(servers))
            storedServers = servers
        }
    }

    func credentials(for serverID: String) throws -> ServerCredentials? {
        lock.withLock { storedCredentials[serverID] }
    }

    func save(_ credentials: ServerCredentials, for serverID: String) throws {
        lock.withLock { storedCredentials[serverID] = credentials }
    }

    func deleteCredentials(for serverID: String) throws {
        try lock.withLock {
            events.append(.deleteCredentials(serverID))
            if failingDeletionIDs.contains(serverID) {
                throw ResetError.credentialDeletion(serverID)
            }
            storedCredentials[serverID] = nil
        }
    }
}

@MainActor
final class ServerStoreTests: XCTestCase {
    func testDebugResetClearsMetadataBeforeDeletingEveryKnownCredential() throws {
        let first = AdminServer.fixture
        let second = AdminServer(
            id: "second-server",
            baseURL: URL(string: "https://second.example.test")!,
            displayName: "Second"
        )
        let persistence = RecordingResetStore(
            servers: [first, second],
            credentials: .fixture
        )
        let configuration = DebugLaunchConfiguration(arguments: [
            "BloemAdmin",
            "--ui-testing-reset",
        ])

        try configuration.resetPersistedState(
            metadataStore: persistence,
            credentialStore: persistence
        )

        XCTAssertEqual(
            persistence.events,
            [
                .loadServers,
                .saveServers([]),
                .deleteCredentials("test-server"),
                .deleteCredentials("second-server"),
            ]
        )
        XCTAssertTrue(try persistence.loadServers().isEmpty)
        XCTAssertNil(try persistence.credentials(for: first.id))
        XCTAssertNil(try persistence.credentials(for: second.id))
    }

    func testDebugResetDoesNothingWithoutResetArgument() throws {
        let persistence = RecordingResetStore(
            servers: [.fixture],
            credentials: .fixture
        )
        let configuration = DebugLaunchConfiguration(arguments: ["BloemAdmin"])

        try configuration.resetPersistedState(
            metadataStore: persistence,
            credentialStore: persistence
        )

        XCTAssertTrue(persistence.events.isEmpty)
        XCTAssertEqual(try persistence.loadServers(), [.fixture])
        XCTAssertEqual(try persistence.credentials(for: AdminServer.fixture.id), .fixture)
    }

    func testDebugResetAttemptsEveryCredentialDeletionBeforeRethrowingFirstFailure() throws {
        let first = AdminServer.fixture
        let second = AdminServer(
            id: "second-server",
            baseURL: URL(string: "https://second.example.test")!,
            displayName: "Second"
        )
        let persistence = RecordingResetStore(
            servers: [first, second],
            credentials: .fixture,
            failingDeletionIDs: [first.id]
        )
        let configuration = DebugLaunchConfiguration(arguments: [
            "BloemAdmin",
            "--ui-testing-reset",
        ])

        XCTAssertThrowsError(
            try configuration.resetPersistedState(
                metadataStore: persistence,
                credentialStore: persistence
            )
        ) { error in
            XCTAssertEqual(error as? RecordingResetStore.ResetError, .credentialDeletion(first.id))
        }
        XCTAssertEqual(
            persistence.events,
            [
                .loadServers,
                .saveServers([]),
                .deleteCredentials(first.id),
                .deleteCredentials(second.id),
            ]
        )
        XCTAssertNotNil(try persistence.credentials(for: first.id))
        XCTAssertNil(try persistence.credentials(for: second.id))
    }

    func testUserDefaultsMetadataStoresAreIsolatedBySuite() throws {
        let firstSuite = "BloemAdminTests.first.\(UUID().uuidString)"
        let secondSuite = "BloemAdminTests.second.\(UUID().uuidString)"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }

        let credentials = InMemoryCredentialStore()
        let firstStore = ServerStore(
            metadataStore: UserDefaultsServerMetadataStore(defaults: firstDefaults),
            credentialStore: credentials
        )
        let secondStore = ServerStore(
            metadataStore: UserDefaultsServerMetadataStore(defaults: secondDefaults),
            credentialStore: InMemoryCredentialStore()
        )
        try firstStore.addServer(.fixture, credentials: .fixture)

        XCTAssertEqual(firstStore.servers, [.fixture])
        XCTAssertTrue(secondStore.servers.isEmpty)
    }

    func testCredentialReplacementIsOneAtomicSave() throws {
        let credentials = InMemoryCredentialStore()
        let store = ServerStore(metadataStore: InMemoryServerMetadataStore(), credentialStore: credentials)
        try store.addServer(.fixture, credentials: .fixture)
        try store.updateCredentials(.rotated, forServerID: AdminServer.fixture.id)
        XCTAssertEqual(try credentials.credentials(for: AdminServer.fixture.id), .rotated)
        XCTAssertEqual(credentials.saveCalls.map(\.credentials), [.fixture, .rotated])
    }

    func testAddServerPersistsMetadataAndCombinedCredentials() throws {
        let metadata = InMemoryServerMetadataStore()
        let credentials = InMemoryCredentialStore()
        let store = ServerStore(metadataStore: metadata, credentialStore: credentials)

        try store.addServer(.fixture, credentials: .fixture)

        XCTAssertEqual(store.servers, [.fixture])
        XCTAssertEqual(try metadata.loadServers(), [.fixture])
        XCTAssertEqual(try credentials.credentials(for: AdminServer.fixture.id), .fixture)
    }

    func testRemoveServerDeletesMetadataAndCombinedCredentials() throws {
        let metadata = InMemoryServerMetadataStore()
        let credentials = InMemoryCredentialStore()
        let store = ServerStore(metadataStore: metadata, credentialStore: credentials)
        try store.addServer(.fixture, credentials: .fixture)

        try store.removeServer(AdminServer.fixture.id)

        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertTrue(try metadata.loadServers().isEmpty)
        XCTAssertNil(try credentials.credentials(for: AdminServer.fixture.id))
    }

    func testUpdateTokenPreservesRefreshTokenWhenReplacementIsOmitted() throws {
        let credentials = InMemoryCredentialStore(credentialsByServerID: [AdminServer.fixture.id: .fixture])
        let store = ServerStore(metadataStore: InMemoryServerMetadataStore(), credentialStore: credentials)

        try store.updateToken("new-access", forServerID: AdminServer.fixture.id)

        XCTAssertEqual(
            try credentials.credentials(for: AdminServer.fixture.id),
            ServerCredentials(
                version: ServerCredentials.currentVersion,
                accessToken: "new-access",
                refreshToken: ServerCredentials.fixture.refreshToken
            )
        )
    }

    func testMetadataFailureRollsBackNewCredentials() {
        let metadata = InMemoryServerMetadataStore(saveError: TestError.expected)
        let credentials = InMemoryCredentialStore()
        let store = ServerStore(metadataStore: metadata, credentialStore: credentials)
        XCTAssertThrowsError(try store.addServer(.fixture, credentials: .fixture))
        XCTAssertNil(try credentials.credentials(for: AdminServer.fixture.id))
    }

    func testRenameFailureKeepsPublishedAndPersistedNameUnchanged() throws {
        let metadata = InMemoryServerMetadataStore()
        let store = ServerStore(
            metadataStore: metadata,
            credentialStore: InMemoryCredentialStore()
        )
        try store.addServer(.fixture, credentials: .fixture)
        metadata.saveError = TestError.expected

        XCTAssertThrowsError(try store.renameServer(AdminServer.fixture.id, to: "Changed"))
        XCTAssertEqual(store.servers.first?.displayName, AdminServer.fixture.displayName)
        XCTAssertEqual(try metadata.loadServers().first?.displayName, AdminServer.fixture.displayName)
    }

    func testRenamePersistsBeforePublishingTheNewName() throws {
        let metadata = InMemoryServerMetadataStore(servers: [.fixture])
        let store = ServerStore(metadataStore: metadata, credentialStore: InMemoryCredentialStore())

        try store.renameServer(AdminServer.fixture.id, to: "Renamed")

        XCTAssertEqual(store.servers.first?.displayName, "Renamed")
        XCTAssertEqual(try metadata.loadServers().first?.displayName, "Renamed")
    }

    func testRenameUnknownServerIsNoOp() throws {
        let metadata = InMemoryServerMetadataStore(servers: [.fixture])
        let store = ServerStore(metadataStore: metadata, credentialStore: InMemoryCredentialStore())

        try store.renameServer("unknown", to: "Changed")

        XCTAssertEqual(store.servers, [.fixture])
        XCTAssertEqual(try metadata.loadServers(), [.fixture])
    }

    func testInitializationFailureIsRetainedForUIReporting() {
        let store = ServerStore(
            metadataStore: InMemoryServerMetadataStore(loadError: TestError.expected),
            credentialStore: InMemoryCredentialStore()
        )

        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertNotNil(store.initializationError)
    }

    func testRemovalDeletionFailureKeepsServerPublishedAndPersisted() throws {
        let metadata = InMemoryServerMetadataStore()
        let credentials = InMemoryCredentialStore(deleteError: TestError.expected)
        let store = ServerStore(metadataStore: metadata, credentialStore: credentials)
        try store.addServer(.fixture, credentials: .fixture)

        XCTAssertThrowsError(try store.removeServer(AdminServer.fixture.id))
        XCTAssertEqual(store.servers, [.fixture])
        XCTAssertEqual(try metadata.loadServers(), [.fixture])
    }

    func testSignOutPropagatesCredentialDeletionFailure() throws {
        let credentials = InMemoryCredentialStore(deleteError: TestError.expected)
        let store = ServerStore(metadataStore: InMemoryServerMetadataStore(), credentialStore: credentials)
        try store.addServer(.fixture, credentials: .fixture)

        XCTAssertThrowsError(try store.signOut(AdminServer.fixture.id))
        XCTAssertEqual(try credentials.credentials(for: AdminServer.fixture.id), .fixture)
    }

    func testSignOutDeletesCredentialsButKeepsServerMetadata() throws {
        let metadata = InMemoryServerMetadataStore()
        let credentials = InMemoryCredentialStore()
        let store = ServerStore(metadataStore: metadata, credentialStore: credentials)
        try store.addServer(.fixture, credentials: .fixture)

        try store.signOut(AdminServer.fixture.id)

        XCTAssertEqual(store.servers, [.fixture])
        XCTAssertEqual(try metadata.loadServers(), [.fixture])
        XCTAssertNil(try credentials.credentials(for: AdminServer.fixture.id))
    }
}
