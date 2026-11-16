import Foundation
import Security
import XCTest
@testable import BloemAdmin

final class ServerCredentialsTests: XCTestCase {
    func testSaveUpdatesBeforeAddingWhenRecordDoesNotExist() throws {
        let recorder = SecurityRecorder()
        let store = KeychainCredentialStore(securityClient: recorder.client)

        try store.save(.fixture, for: AdminServer.fixture.id)

        XCTAssertEqual(recorder.mutations, [.update, .add])
        XCTAssertEqual(try store.credentials(for: AdminServer.fixture.id), .fixture)
    }

    func testSaveMakesCombinedCredentialsAvailableOnlyWhileDeviceIsUnlocked() throws {
        let recorder = SecurityRecorder()
        let store = KeychainCredentialStore(securityClient: recorder.client)

        try store.save(.fixture, for: AdminServer.fixture.id)

        XCTAssertEqual(recorder.addedAccessibility, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(recorder.updatedAccessibility, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testReadUpgradesExistingCombinedCredentialsToWhenUnlocked() throws {
        let recorder = SecurityRecorder()
        try recorder.seedCombined(
            .fixture,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            serverID: AdminServer.fixture.id
        )
        let store = KeychainCredentialStore(securityClient: recorder.client)

        XCTAssertEqual(try store.credentials(for: AdminServer.fixture.id), .fixture)

        XCTAssertEqual(
            recorder.combinedAccessibility(serverID: AdminServer.fixture.id),
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(recorder.mutations, [.update, .delete, .delete])
    }

    func testFailedCombinedAccessibilityUpgradePreservesCredentials() throws {
        let recorder = SecurityRecorder()
        try recorder.seedCombined(
            .fixture,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            serverID: AdminServer.fixture.id
        )
        recorder.updateStatuses = [errSecInteractionNotAllowed]
        let store = KeychainCredentialStore(securityClient: recorder.client)

        XCTAssertThrowsError(try store.credentials(for: AdminServer.fixture.id))

        XCTAssertEqual(recorder.combinedCredentials(serverID: AdminServer.fixture.id), .fixture)
        XCTAssertEqual(
            recorder.combinedAccessibility(serverID: AdminServer.fixture.id),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(recorder.mutations, [.update])
    }

    func testSaveDoesNotAddWhenUpdateFailsForAnotherReason() throws {
        let recorder = SecurityRecorder()
        let store = KeychainCredentialStore(securityClient: recorder.client)
        try store.save(.fixture, for: AdminServer.fixture.id)
        recorder.updateStatuses = [errSecInteractionNotAllowed]

        XCTAssertThrowsError(try store.save(.rotated, for: AdminServer.fixture.id))
        XCTAssertEqual(recorder.mutations, [.update, .add, .update])
        XCTAssertEqual(try store.credentials(for: AdminServer.fixture.id), .fixture)
    }

    func testSaveReplacesTheCompleteCombinedRecord() throws {
        let recorder = SecurityRecorder()
        let store = KeychainCredentialStore(securityClient: recorder.client)
        try store.save(.fixture, for: AdminServer.fixture.id)

        try store.save(.rotated, for: AdminServer.fixture.id)

        XCTAssertEqual(recorder.mutations, [.update, .add, .update])
        XCTAssertEqual(try store.credentials(for: AdminServer.fixture.id), .rotated)
    }

    func testDeletePropagatesUnexpectedSecurityError() throws {
        let recorder = SecurityRecorder()
        recorder.deleteStatuses = [errSecInteractionNotAllowed]
        let store = KeychainCredentialStore(securityClient: recorder.client)

        XCTAssertThrowsError(try store.deleteCredentials(for: AdminServer.fixture.id))
    }

    func testDeleteBeforeFirstReadRemovesLegacyCredentialsWithoutMigratingThem() throws {
        let recorder = SecurityRecorder()
        recorder.seedLegacy(
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh",
            serverID: AdminServer.fixture.id
        )
        let store = KeychainCredentialStore(securityClient: recorder.client)

        try store.deleteCredentials(for: AdminServer.fixture.id)

        XCTAssertNil(try store.credentials(for: AdminServer.fixture.id))
        XCTAssertNil(recorder.legacyAccessToken(serverID: AdminServer.fixture.id))
        XCTAssertNil(recorder.legacyRefreshToken(serverID: AdminServer.fixture.id))
    }

    func testDeleteSweepsEveryCredentialNamespaceBeforeSurfacingAnUnexpectedError() throws {
        let recorder = SecurityRecorder()
        try recorder.seedCombined(
            .fixture,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            serverID: AdminServer.fixture.id
        )
        recorder.seedLegacy(
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh",
            serverID: AdminServer.fixture.id
        )
        recorder.deleteStatuses = [errSecSuccess, errSecInteractionNotAllowed, errSecSuccess]
        let store = KeychainCredentialStore(securityClient: recorder.client)

        XCTAssertThrowsError(try store.deleteCredentials(for: AdminServer.fixture.id))

        XCTAssertNil(recorder.combinedCredentials(serverID: AdminServer.fixture.id))
        XCTAssertEqual(recorder.legacyAccessToken(serverID: AdminServer.fixture.id), "legacy-access")
        XCTAssertNil(recorder.legacyRefreshToken(serverID: AdminServer.fixture.id))
    }

    func testMigrationDeletesLegacyRecordsOnlyAfterCombinedRecordReadsBack() throws {
        let recorder = SecurityRecorder()
        recorder.seedLegacy(accessToken: "legacy-access", refreshToken: "legacy-refresh", serverID: AdminServer.fixture.id)
        let store = KeychainCredentialStore(securityClient: recorder.client)

        let migrated = try store.credentials(for: AdminServer.fixture.id)

        XCTAssertEqual(migrated, ServerCredentials(
            version: ServerCredentials.currentVersion,
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh"
        ))
        XCTAssertEqual(recorder.deletedServices, [
            "com.bloemstudios.admin.token",
            "com.bloemstudios.admin.refreshtoken",
        ])
        let readBackIndex = try XCTUnwrap(recorder.firstCombinedReadIndexAfterAdd)
        XCTAssertEqual(Array(recorder.operations[..<readBackIndex]), [.copy, .copy, .copy, .update, .add])
    }

    func testMigrationReadBackFailurePreservesLegacyRecords() throws {
        let recorder = SecurityRecorder()
        recorder.seedLegacy(accessToken: "legacy-access", refreshToken: "legacy-refresh", serverID: AdminServer.fixture.id)
        recorder.copyStatuses = [nil, nil, nil, errSecDecode]
        let store = KeychainCredentialStore(securityClient: recorder.client)

        XCTAssertThrowsError(try store.credentials(for: AdminServer.fixture.id))
        XCTAssertTrue(recorder.deletedServices.isEmpty)
        XCTAssertEqual(recorder.legacyAccessToken(serverID: AdminServer.fixture.id), "legacy-access")
        XCTAssertEqual(recorder.legacyRefreshToken(serverID: AdminServer.fixture.id), "legacy-refresh")
    }

    func testCombinedReadRetriesLegacyCleanupAfterPartialMigrationDeletionFailure() throws {
        let recorder = SecurityRecorder()
        recorder.seedLegacy(
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh",
            serverID: AdminServer.fixture.id
        )
        recorder.deleteStatuses = [errSecSuccess, errSecInteractionNotAllowed]
        let store = KeychainCredentialStore(securityClient: recorder.client)
        let migrated = ServerCredentials(
            version: ServerCredentials.currentVersion,
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh"
        )

        XCTAssertThrowsError(try store.credentials(for: AdminServer.fixture.id))
        XCTAssertEqual(recorder.combinedCredentials(serverID: AdminServer.fixture.id), migrated)
        XCTAssertNil(recorder.legacyAccessToken(serverID: AdminServer.fixture.id))
        XCTAssertEqual(recorder.legacyRefreshToken(serverID: AdminServer.fixture.id), "legacy-refresh")

        XCTAssertEqual(try store.credentials(for: AdminServer.fixture.id), migrated)
        XCTAssertEqual(recorder.combinedCredentials(serverID: AdminServer.fixture.id), migrated)
        XCTAssertNil(recorder.legacyAccessToken(serverID: AdminServer.fixture.id))
        XCTAssertNil(recorder.legacyRefreshToken(serverID: AdminServer.fixture.id))
    }

    func testIndependentStoresSerializeCapturedLegacyMigrationBeforeDelete() throws {
        let recorder = SecurityRecorder()
        recorder.seedLegacy(
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh",
            serverID: AdminServer.fixture.id
        )
        let migrationReachedSave = DispatchSemaphore(value: 0)
        let allowMigrationSave = DispatchSemaphore(value: 0)
        recorder.beforeNextUpdate = {
            migrationReachedSave.signal()
            allowMigrationSave.wait()
        }
        let migrationStore = KeychainCredentialStore(securityClient: recorder.client)
        let deletionStore = KeychainCredentialStore(securityClient: recorder.client)
        let migrationFinished = DispatchSemaphore(value: 0)
        let deleteFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = try? migrationStore.credentials(for: AdminServer.fixture.id)
            migrationFinished.signal()
        }
        XCTAssertEqual(migrationReachedSave.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            try? deletionStore.deleteCredentials(for: AdminServer.fixture.id)
            deleteFinished.signal()
        }
        let deleteReturnedBeforeMigration = deleteFinished.wait(timeout: .now() + 0.25) == .success
        allowMigrationSave.signal()

        XCTAssertEqual(migrationFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(deleteFinished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(deleteReturnedBeforeMigration)
        XCTAssertNil(try migrationStore.credentials(for: AdminServer.fixture.id))
    }
}

private final class SecurityRecorder: @unchecked Sendable {
    enum Operation: Equatable { case copy, update, add, delete }

    private struct ItemKey: Hashable {
        let service: String
        let account: String
    }

    // Every read and mutation of the recorder's non-Sendable dictionaries
    // and scripted result queues is serialized by this lock.
    private let lock = NSLock()
    private var items: [ItemKey: Data] = [:]
    private var recordedOperations: [Operation] = []
    private var recordedDeletedServices: [String] = []
    private var scriptedCopyStatuses: [OSStatus?] = []
    private var scriptedUpdateStatuses: [OSStatus] = []
    private var scriptedAddStatuses: [OSStatus] = []
    private var scriptedDeleteStatuses: [OSStatus] = []
    private var recordedAddedAccessibility: String?
    private var recordedUpdatedAccessibility: String?
    private var accessibilityByItem: [ItemKey: String] = [:]
    private var pendingBeforeNextUpdate: (() -> Void)?

    var client: SecurityClient {
        SecurityClient(
            copyMatching: { [weak self] query, result in self?.copyMatching(query, result: result) ?? errSecNotAvailable },
            update: { [weak self] query, attributes in self?.update(query, attributes: attributes) ?? errSecNotAvailable },
            add: { [weak self] query, result in self?.add(query, result: result) ?? errSecNotAvailable },
            delete: { [weak self] query in self?.delete(query) ?? errSecNotAvailable }
        )
    }

    var operations: [Operation] { lock.withLock { recordedOperations } }
    var mutations: [Operation] { operations.filter { $0 != .copy } }
    var deletedServices: [String] { lock.withLock { recordedDeletedServices } }
    var addedAccessibility: String? { lock.withLock { recordedAddedAccessibility } }
    var updatedAccessibility: String? { lock.withLock { recordedUpdatedAccessibility } }

    var copyStatuses: [OSStatus?] {
        get { lock.withLock { scriptedCopyStatuses } }
        set { lock.withLock { scriptedCopyStatuses = newValue } }
    }

    var updateStatuses: [OSStatus] {
        get { lock.withLock { scriptedUpdateStatuses } }
        set { lock.withLock { scriptedUpdateStatuses = newValue } }
    }

    var addStatuses: [OSStatus] {
        get { lock.withLock { scriptedAddStatuses } }
        set { lock.withLock { scriptedAddStatuses = newValue } }
    }

    var deleteStatuses: [OSStatus] {
        get { lock.withLock { scriptedDeleteStatuses } }
        set { lock.withLock { scriptedDeleteStatuses = newValue } }
    }

    var beforeNextUpdate: (() -> Void)? {
        get { lock.withLock { pendingBeforeNextUpdate } }
        set { lock.withLock { pendingBeforeNextUpdate = newValue } }
    }

    var firstCombinedReadIndexAfterAdd: Int? {
        let operations = operations
        guard let addIndex = operations.firstIndex(of: .add) else { return nil }
        return operations.indices.first { $0 > addIndex && operations[$0] == .copy }
    }

    func seedLegacy(accessToken: String, refreshToken: String?, serverID: String) {
        lock.withLock {
            items[ItemKey(service: "com.bloemstudios.admin.token", account: serverID)] = Data(accessToken.utf8)
            if let refreshToken {
                items[ItemKey(service: "com.bloemstudios.admin.refreshtoken", account: serverID)] = Data(refreshToken.utf8)
            }
        }
    }

    func seedCombined(_ credentials: ServerCredentials, accessibility: String, serverID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        lock.withLock {
            let key = ItemKey(service: KeychainCredentialStore.service, account: serverID)
            items[key] = data
            accessibilityByItem[key] = accessibility
        }
    }

    func combinedCredentials(serverID: String) -> ServerCredentials? {
        lock.withLock {
            let key = ItemKey(service: KeychainCredentialStore.service, account: serverID)
            guard let data = items[key] else { return nil }
            return try? JSONDecoder().decode(ServerCredentials.self, from: data)
        }
    }

    func combinedAccessibility(serverID: String) -> String? {
        lock.withLock {
            accessibilityByItem[ItemKey(service: KeychainCredentialStore.service, account: serverID)]
        }
    }

    func legacyAccessToken(serverID: String) -> String? {
        stringValue(service: "com.bloemstudios.admin.token", serverID: serverID)
    }

    func legacyRefreshToken(serverID: String) -> String? {
        stringValue(service: "com.bloemstudios.admin.refreshtoken", serverID: serverID)
    }

    private func stringValue(service: String, serverID: String) -> String? {
        lock.withLock {
            items[ItemKey(service: service, account: serverID)].flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    private func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.withLock {
            recordedOperations.append(.copy)
            if !scriptedCopyStatuses.isEmpty, let status = scriptedCopyStatuses.removeFirst() {
                return status
            }
            guard let key = key(from: query), let data = items[key] else { return errSecItemNotFound }
            result?.pointee = data as CFData
            return errSecSuccess
        }
    }

    private func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        let beforeUpdate = lock.withLock {
            let pending = pendingBeforeNextUpdate
            pendingBeforeNextUpdate = nil
            return pending
        }
        beforeUpdate?()

        return lock.withLock {
            recordedOperations.append(.update)
            recordedUpdatedAccessibility = dictionary(attributes)[kSecAttrAccessible as String] as? String
            if !scriptedUpdateStatuses.isEmpty { return scriptedUpdateStatuses.removeFirst() }
            guard let key = key(from: query), items[key] != nil else { return errSecItemNotFound }
            let values = dictionary(attributes)
            if let data = values[kSecValueData as String] as? Data {
                items[key] = data
            }
            if let accessibility = values[kSecAttrAccessible as String] as? String {
                accessibilityByItem[key] = accessibility
            }
            return errSecSuccess
        }
    }

    private func add(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.withLock {
            recordedOperations.append(.add)
            recordedAddedAccessibility = dictionary(query)[kSecAttrAccessible as String] as? String
            if !scriptedAddStatuses.isEmpty { return scriptedAddStatuses.removeFirst() }
            guard let key = key(from: query) else { return errSecParam }
            guard items[key] == nil else { return errSecDuplicateItem }
            guard let data = dictionary(query)[kSecValueData as String] as? Data else { return errSecParam }
            items[key] = data
            if let accessibility = dictionary(query)[kSecAttrAccessible as String] as? String {
                accessibilityByItem[key] = accessibility
            }
            return errSecSuccess
        }
    }

    private func delete(_ query: CFDictionary) -> OSStatus {
        lock.withLock {
            recordedOperations.append(.delete)
            if !scriptedDeleteStatuses.isEmpty {
                let status = scriptedDeleteStatuses.removeFirst()
                if status != errSecSuccess { return status }
            }
            guard let key = key(from: query) else { return errSecParam }
            guard items.removeValue(forKey: key) != nil else { return errSecItemNotFound }
            accessibilityByItem[key] = nil
            recordedDeletedServices.append(key.service)
            return errSecSuccess
        }
    }

    private func key(from query: CFDictionary) -> ItemKey? {
        let values = dictionary(query)
        guard let service = values[kSecAttrService as String] as? String,
              let account = values[kSecAttrAccount as String] as? String else { return nil }
        return ItemKey(service: service, account: account)
    }

    private func dictionary(_ value: CFDictionary) -> [String: Any] {
        value as NSDictionary as? [String: Any] ?? [:]
    }
}
