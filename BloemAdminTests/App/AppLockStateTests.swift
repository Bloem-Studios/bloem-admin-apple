import XCTest
@testable import BloemAdmin

/// Mock `BiometricAuthenticating` — lets `AppLockStateTests` exercise
/// `AppLockState`'s full lock/unlock state machine without any real
/// `LAContext`/biometric hardware interaction, which `xcodebuild test` can't
/// drive. What's covered here: scenePhase-driven lock/unlock transitions,
/// fail-closed unavailable authentication, stale and overlapping attempts,
/// and the "Unlock" button's success/failure paths. What's deliberately NOT
/// covered (and can't be, in this kind of test): the real Face ID/Touch ID prompt UI
/// itself, `LAContext.canEvaluatePolicy`/`evaluatePolicy`'s actual behavior,
/// or the `NSFaceIDUsageDescription` Info.plist wiring — those require a
/// real device/simulator with biometrics configured and manual or UI-test
/// interaction.
final class MockBiometricAuthenticator: BiometricAuthenticating {
    var canAuthenticateResult = true
    var authenticateResult = true
    private(set) var authenticateCallCount = 0

    func canAuthenticate() -> Bool { canAuthenticateResult }

    func authenticate() async -> Bool {
        authenticateCallCount += 1
        return authenticateResult
    }
}

final class ControllableBiometricAuthenticator: BiometricAuthenticating {
    var canAuthenticateResult = true
    var onAuthenticationStarted: (() -> Void)?
    private(set) var authenticateCallCount = 0
    private var completions: [Int: CheckedContinuation<Bool, Never>] = [:]

    func canAuthenticate() -> Bool { canAuthenticateResult }

    func authenticate() async -> Bool {
        authenticateCallCount += 1
        let attempt = authenticateCallCount
        onAuthenticationStarted?()
        return await withCheckedContinuation { continuation in
            completions[attempt] = continuation
        }
    }

    func completeAttempt(_ attempt: Int, with result: Bool) {
        completions.removeValue(forKey: attempt)?.resume(returning: result)
    }
}

@MainActor
final class RecordingProtectedUISecurer: ProtectedUISecuring {
    private(set) var securedSceneIDs: [AppSceneID] = []

    func secureForLock(sceneID: AppSceneID) {
        securedSceneIDs.append(sceneID)
    }
}

@MainActor
final class RecordingSceneProtectionShield: SceneProtectedUIShielding {
    let sceneID: AppSceneID
    private(set) var secureCallCount = 0

    init(sceneID: AppSceneID) {
        self.sceneID = sceneID
    }

    func secureForLock() {
        secureCallCount += 1
    }
}

@MainActor
final class AppLockStateTests: XCTestCase {
    func testDebugLaunchConfigurationParsesOnlySupportedUITestArguments() {
        let configuration = DebugLaunchConfiguration(arguments: [
            "BloemAdmin",
            "--ui-testing-reset",
            "--ui-testing-auth=success-then-pending",
            "--unrelated-argument",
        ])

        XCTAssertTrue(configuration.resetsPersistedState)
        XCTAssertEqual(configuration.authenticationMode, .successThenPending)
    }

    func testDebugLaunchConfigurationDefaultsToProductionPolicies() {
        let configuration = DebugLaunchConfiguration(arguments: [
            "BloemAdmin",
            "--ui-testing-auth=unsupported",
        ])

        XCTAssertFalse(configuration.resetsPersistedState)
        XCTAssertEqual(configuration.authenticationMode, .system)
        XCTAssertFalse(configuration.isUITesting)
    }

    func testDebugSuccessAuthenticatorAuthenticatesImmediately() async {
        let configuration = DebugLaunchConfiguration(arguments: [
            "BloemAdmin",
            "--ui-testing-auth=success",
        ])
        let authenticator = configuration.makeAuthenticator()

        XCTAssertTrue(authenticator.canAuthenticate())
        let authenticated = await authenticator.authenticate()
        XCTAssertTrue(authenticated)
    }

    func testDebugUnavailableAuthenticatorFailsClosedWithoutPrompting() async {
        let configuration = DebugLaunchConfiguration(arguments: [
            "BloemAdmin",
            "--ui-testing-auth=unavailable",
        ])
        let authenticator = configuration.makeAuthenticator()

        XCTAssertFalse(authenticator.canAuthenticate())
        let authenticated = await authenticator.authenticate()
        XCTAssertFalse(authenticated)
    }

    func testDebugSuccessThenPendingAuthenticatorLeavesLaterPromptPending() async {
        let configuration = DebugLaunchConfiguration(arguments: [
            "BloemAdmin",
            "--ui-testing-auth=success-then-pending",
        ])
        let authenticator = configuration.makeAuthenticator()
        let firstAuthenticated = await authenticator.authenticate()
        XCTAssertTrue(firstAuthenticated)

        let laterPromptCompleted = expectation(description: "later prompt completed")
        laterPromptCompleted.isInverted = true
        let laterPrompt = Task {
            _ = await authenticator.authenticate()
            laterPromptCompleted.fulfill()
        }

        await fulfillment(of: [laterPromptCompleted], timeout: 0.1)
        laterPrompt.cancel()
        _ = await laterPrompt.value
    }

    func testStartsLockedByDefault() {
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: MockBiometricAuthenticator())
        XCTAssertTrue(state.isLocked(for: sceneID))
    }

    func testCanStartUnlockedForTestingConvenience() {
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: MockBiometricAuthenticator(), startLocked: false)
        XCTAssertFalse(state.isLocked(for: sceneID))
    }

    func testBackgroundingAlwaysRelocksRegardlessOfPriorState() {
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: MockBiometricAuthenticator(), startLocked: false)
        XCTAssertFalse(state.isLocked(for: sceneID))

        state.handleScenePhaseChange(.background, for: sceneID)

        XCTAssertTrue(state.isLocked(for: sceneID))
    }

    func testBecomingActiveWhileLockedStaysLockedWhenBiometricsAvailable() {
        let authenticator = MockBiometricAuthenticator()
        authenticator.canAuthenticateResult = true
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)

        state.handleScenePhaseChange(.active, for: sceneID)

        XCTAssertTrue(state.isLocked(for: sceneID), "must stay locked and wait for an explicit unlock() when biometrics ARE available")
    }

    func testUnavailableAuthenticationStaysLocked() async {
        let authenticator = MockBiometricAuthenticator()
        authenticator.canAuthenticateResult = false
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)

        state.handleScenePhaseChange(.active, for: sceneID)
        await state.unlock(for: sceneID)

        XCTAssertTrue(state.isLocked(for: sceneID))
        XCTAssertEqual(state.availability, .unavailable)
        XCTAssertEqual(authenticator.authenticateCallCount, 0)
    }

    /// Review finding I2: iOS snapshots the app for the app-switcher
    /// preview around the resign-active/background transition, which fires
    /// `.inactive` (not just `.background`) — an app holding real admin
    /// credentials must not let that snapshot capture live user lists,
    /// stream sessions, or quotas. `.inactive` now locks immediately, same
    /// as `.background`, rather than being a no-op.
    func testInactiveAlsoLocksImmediatelyToAvoidAppSwitcherSnapshotExposure() {
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: MockBiometricAuthenticator(), startLocked: false)
        XCTAssertFalse(state.isLocked(for: sceneID))

        state.handleScenePhaseChange(.inactive, for: sceneID)

        XCTAssertTrue(state.isLocked(for: sceneID))
    }

    func testInactiveSynchronouslySecuresPresentedAndFocusedUI() {
        let protectedUI = RecordingProtectedUISecurer()
        let sceneID = AppSceneID()
        let state = AppLockState(
            authenticator: MockBiometricAuthenticator(),
            startLocked: false,
            protectedUI: protectedUI
        )

        state.handleScenePhaseChange(.inactive, for: sceneID)

        XCTAssertEqual(protectedUI.securedSceneIDs, [sceneID])
    }

    func testBackgroundSynchronouslySecuresPresentedAndFocusedUI() {
        let protectedUI = RecordingProtectedUISecurer()
        let sceneID = AppSceneID()
        let state = AppLockState(
            authenticator: MockBiometricAuthenticator(),
            startLocked: false,
            protectedUI: protectedUI
        )

        state.handleScenePhaseChange(.background, for: sceneID)

        XCTAssertEqual(protectedUI.securedSceneIDs, [sceneID])
    }

    func testApplicationProtectedUISecurerEndsEditingAndShowsOnlyTargetSceneShieldSynchronously() {
        var didEndEditing = false
        let protectedUI = ApplicationProtectedUISecurer {
            didEndEditing = true
        }
        let firstScene = RecordingSceneProtectionShield(sceneID: AppSceneID())
        let secondScene = RecordingSceneProtectionShield(sceneID: AppSceneID())
        protectedUI.register(firstScene)
        protectedUI.register(secondScene)

        protectedUI.secureForLock(sceneID: firstScene.sceneID)

        XCTAssertTrue(didEndEditing)
        XCTAssertEqual(firstScene.secureCallCount, 1)
        XCTAssertEqual(secondScene.secureCallCount, 0)
    }

    func testUnlockSucceedsWhenAuthenticatorSucceeds() async {
        let authenticator = MockBiometricAuthenticator()
        authenticator.canAuthenticateResult = true
        authenticator.authenticateResult = true
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)

        await state.unlock(for: sceneID)

        XCTAssertFalse(state.isLocked(for: sceneID))
        XCTAssertEqual(authenticator.authenticateCallCount, 1)
    }

    func testUnlockStaysLockedWhenAuthenticatorFails() async {
        let authenticator = MockBiometricAuthenticator()
        authenticator.canAuthenticateResult = true
        authenticator.authenticateResult = false
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)

        await state.unlock(for: sceneID)

        XCTAssertTrue(state.isLocked(for: sceneID))
    }

    func testUnlockWhileInactiveDoesNotInvokeAuthenticator() async {
        let authenticator = MockBiometricAuthenticator()
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)
        state.handleScenePhaseChange(.inactive, for: sceneID)

        await state.unlock(for: sceneID)

        XCTAssertTrue(state.isLocked(for: sceneID))
        XCTAssertEqual(authenticator.authenticateCallCount, 0)
    }

    func testUnlockWhileBackgroundedDoesNotInvokeAuthenticator() async {
        let authenticator = MockBiometricAuthenticator()
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)
        state.handleScenePhaseChange(.background, for: sceneID)

        await state.unlock(for: sceneID)

        XCTAssertTrue(state.isLocked(for: sceneID))
        XCTAssertEqual(authenticator.authenticateCallCount, 0)
    }

    func testDelayedUnlockAfterSceneUnregisterDoesNotAuthenticateOrAffectSurvivingScene() async {
        let authenticator = MockBiometricAuthenticator()
        let destroyedSceneID = AppSceneID()
        let survivingSceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)
        state.handleScenePhaseChange(.active, for: destroyedSceneID)
        state.handleScenePhaseChange(.active, for: survivingSceneID)

        state.unregisterScene(destroyedSceneID)
        await state.unlock(for: destroyedSceneID)

        XCTAssertEqual(authenticator.authenticateCallCount, 0)
        XCTAssertTrue(state.isLocked(for: survivingSceneID))
    }

    func testAutomaticUnlockSynchronizesInitiallyInactiveSceneBeforeAuthenticating() async {
        let authenticator = MockBiometricAuthenticator()
        let protectedUI = RecordingProtectedUISecurer()
        let sceneID = AppSceneID()
        let state = AppLockState(
            authenticator: authenticator,
            startLocked: true,
            protectedUI: protectedUI
        )

        await state.automaticallyUnlock(for: .inactive, sceneID: sceneID)

        XCTAssertTrue(state.isLocked(for: sceneID))
        XCTAssertEqual(authenticator.authenticateCallCount, 0)
        XCTAssertEqual(protectedUI.securedSceneIDs, [sceneID])
    }

    func testAuthenticationSuccessCompletingAfterInactiveStaysLocked() async {
        let authenticator = ControllableBiometricAuthenticator()
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)

        let attempt = await startAuthentication(on: state, sceneID: sceneID, using: authenticator)
        state.handleScenePhaseChange(.inactive, for: sceneID)
        authenticator.completeAttempt(1, with: true)
        await attempt.value
        state.handleScenePhaseChange(.active, for: sceneID)

        XCTAssertTrue(state.isLocked(for: sceneID))
    }

    func testAuthenticationOwnedInactiveActiveSequenceCanUnlock() async {
        let authenticator = ControllableBiometricAuthenticator()
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)

        let attempt = await startAuthentication(on: state, sceneID: sceneID, using: authenticator)
        state.handleScenePhaseChange(.inactive, for: sceneID)
        state.handleScenePhaseChange(.active, for: sceneID)
        authenticator.completeAttempt(1, with: true)
        await attempt.value

        XCTAssertFalse(state.isLocked(for: sceneID))
    }

    func testBackgroundingInvalidatesAuthenticationOwnedInactiveSequence() async {
        let authenticator = ControllableBiometricAuthenticator()
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)

        let attempt = await startAuthentication(on: state, sceneID: sceneID, using: authenticator)
        state.handleScenePhaseChange(.inactive, for: sceneID)
        state.handleScenePhaseChange(.background, for: sceneID)
        state.handleScenePhaseChange(.active, for: sceneID)
        authenticator.completeAttempt(1, with: true)
        await attempt.value

        XCTAssertTrue(state.isLocked(for: sceneID))
    }

    func testConcurrentUnlocksShareSingleSuccessfulAuthentication() async {
        let authenticator = ControllableBiometricAuthenticator()
        let firstSceneID = AppSceneID()
        let secondSceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)
        state.handleScenePhaseChange(.active, for: firstSceneID)
        state.handleScenePhaseChange(.active, for: secondSceneID)

        let firstUnlock = await startAuthentication(on: state, sceneID: firstSceneID, using: authenticator)
        let secondUnlockEntered = expectation(description: "second unlock entered")
        let secondUnlock = Task {
            secondUnlockEntered.fulfill()
            await state.unlock(for: secondSceneID)
        }
        await fulfillment(of: [secondUnlockEntered], timeout: 1)

        authenticator.completeAttempt(1, with: true)
        authenticator.completeAttempt(2, with: true)
        await firstUnlock.value
        await secondUnlock.value

        XCTAssertFalse(state.isLocked(for: firstSceneID))
        XCTAssertFalse(state.isLocked(for: secondSceneID))
        XCTAssertEqual(authenticator.authenticateCallCount, 1)
    }

    func testConcurrentUnlocksShareSingleFailedAuthentication() async {
        let authenticator = ControllableBiometricAuthenticator()
        let firstSceneID = AppSceneID()
        let secondSceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)
        state.handleScenePhaseChange(.active, for: firstSceneID)
        state.handleScenePhaseChange(.active, for: secondSceneID)

        let firstUnlock = await startAuthentication(on: state, sceneID: firstSceneID, using: authenticator)
        let secondUnlockEntered = expectation(description: "second unlock entered")
        let secondUnlock = Task {
            secondUnlockEntered.fulfill()
            await state.unlock(for: secondSceneID)
        }
        await fulfillment(of: [secondUnlockEntered], timeout: 1)

        authenticator.completeAttempt(1, with: false)
        authenticator.completeAttempt(2, with: false)
        await firstUnlock.value
        await secondUnlock.value

        XCTAssertTrue(state.isLocked(for: firstSceneID))
        XCTAssertTrue(state.isLocked(for: secondSceneID))
        XCTAssertEqual(authenticator.authenticateCallCount, 1)
    }

    func testOtherSceneBecomingActiveCannotAuthorizeInactiveOwnerCompletion() async {
        let authenticator = ControllableBiometricAuthenticator()
        let ownerSceneID = AppSceneID()
        let otherSceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)
        state.handleScenePhaseChange(.active, for: ownerSceneID)

        let attempt = await startAuthentication(on: state, sceneID: ownerSceneID, using: authenticator)
        state.handleScenePhaseChange(.inactive, for: ownerSceneID)
        state.handleScenePhaseChange(.active, for: otherSceneID)
        authenticator.completeAttempt(1, with: true)
        await attempt.value

        XCTAssertTrue(state.isLocked(for: ownerSceneID))
        XCTAssertTrue(state.isLocked(for: otherSceneID))
    }

    func testOwnerBackgroundInvalidatesCompletionWithoutBlockingOtherSceneRetry() async {
        let authenticator = ControllableBiometricAuthenticator()
        let ownerSceneID = AppSceneID()
        let otherSceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)
        state.handleScenePhaseChange(.active, for: ownerSceneID)
        state.handleScenePhaseChange(.active, for: otherSceneID)

        let staleAttempt = await startAuthentication(on: state, sceneID: ownerSceneID, using: authenticator)
        state.handleScenePhaseChange(.inactive, for: ownerSceneID)
        state.handleScenePhaseChange(.background, for: ownerSceneID)
        authenticator.completeAttempt(1, with: true)
        await staleAttempt.value

        let retry = await startAuthentication(on: state, sceneID: otherSceneID, using: authenticator)
        authenticator.completeAttempt(2, with: true)
        await retry.value

        XCTAssertTrue(state.isLocked(for: ownerSceneID))
        XCTAssertFalse(state.isLocked(for: otherSceneID))
    }

    func testBackgroundedCoalescedSceneStaysShieldedWhenOwnerSucceeds() async {
        let authenticator = ControllableBiometricAuthenticator()
        let ownerSceneID = AppSceneID()
        let otherSceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)
        state.handleScenePhaseChange(.active, for: ownerSceneID)
        state.handleScenePhaseChange(.active, for: otherSceneID)

        let ownerUnlock = await startAuthentication(on: state, sceneID: ownerSceneID, using: authenticator)
        let otherUnlockEntered = expectation(description: "other scene joined authentication")
        let otherUnlock = Task {
            otherUnlockEntered.fulfill()
            await state.unlock(for: otherSceneID)
        }
        await fulfillment(of: [otherUnlockEntered], timeout: 1)
        state.handleScenePhaseChange(.background, for: otherSceneID)
        authenticator.completeAttempt(1, with: true)
        await ownerUnlock.value
        await otherUnlock.value

        XCTAssertFalse(state.isLocked(for: ownerSceneID))
        XCTAssertTrue(state.isLocked(for: otherSceneID))
        XCTAssertEqual(authenticator.authenticateCallCount, 1)
    }

    func testCurrentActiveSceneAuthenticationSuccessUnlocks() async {
        let authenticator = ControllableBiometricAuthenticator()
        let sceneID = AppSceneID()
        let state = AppLockState(authenticator: authenticator, startLocked: true)

        state.handleScenePhaseChange(.active, for: sceneID)
        let attempt = await startAuthentication(on: state, sceneID: sceneID, using: authenticator)
        authenticator.completeAttempt(1, with: true)
        await attempt.value

        XCTAssertFalse(state.isLocked(for: sceneID))
        XCTAssertEqual(state.availability, .available)
    }

    private func startAuthentication(
        on state: AppLockState,
        sceneID: AppSceneID,
        using authenticator: ControllableBiometricAuthenticator
    ) async -> Task<Void, Never> {
        let started = expectation(description: "authentication prompt started")
        authenticator.onAuthenticationStarted = { started.fulfill() }
        let attempt = Task { await state.unlock(for: sceneID) }
        await fulfillment(of: [started], timeout: 1)
        authenticator.onAuthenticationStarted = nil
        return attempt
    }
}
