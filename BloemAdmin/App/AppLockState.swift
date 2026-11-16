import Foundation
import LocalAuthentication
import Observation

/// Thin protocol wrapper around `LAContext` so `AppLockState`'s
/// scenePhase/unlock logic is unit-testable without driving a real
/// biometric prompt (which requires actual hardware/simulator interaction
/// and can't run under `xcodebuild test`). `LAContextAuthenticator` below is
/// the real implementation; tests inject a mock conforming to this
/// protocol instead.
@MainActor
protocol BiometricAuthenticating {
    /// Whether SOME local authentication (biometrics OR device passcode
    /// fallback) is available at all on this device right now. `false` on a
    /// fresh simulator or a device with nothing enrolled.
    func canAuthenticate() -> Bool
    /// Runs the actual Face ID/Touch ID (with passcode fallback) prompt.
    /// Returns whether it succeeded.
    func authenticate() async -> Bool
}

/// Synchronously protects UIKit presentation and focus state before iOS can
/// snapshot or route another interaction while the scene is resigning active.
@MainActor
protocol ProtectedUISecuring {
    func secureForLock(sceneID: AppSceneID)
}

@MainActor
private struct NoopProtectedUISecurer: ProtectedUISecuring {
    nonisolated init() {}

    func secureForLock(sceneID: AppSceneID) {}
}

/// Stable identity for one mounted `WindowGroup` scene. Lock state and
/// authentication ownership are tracked against this value so lifecycle
/// events from another window cannot authorize or expose this one.
struct AppSceneID: Hashable, Sendable {
    private let rawValue = UUID()
}

/// Real `LAContext`-backed implementation. A fresh `LAContext` is created
/// per call (rather than reused) since Apple's guidance is that a context
/// shouldn't be reused across an invalidated evaluation.
struct LAContextAuthenticator: BiometricAuthenticating {
    nonisolated init() {}

    func canAuthenticate() -> Bool {
        let context = LAContext()
        var error: NSError?
        // deviceOwnerAuthentication (not the Biometrics-only variant)
        // covers both Face ID/Touch ID AND the device passcode fallback
        // named in the requirements.
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func authenticate() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Bloem Admin"
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

#if DEBUG
/// Narrow launch-policy seam used only by the UI-test target. Unsupported or
/// absent arguments preserve the production authentication and persistence
/// behavior.
struct DebugLaunchConfiguration {
    enum AuthenticationMode: Equatable {
        case system
        case success
        case unavailable
        case successThenPending
    }

    let resetsPersistedState: Bool
    let authenticationMode: AuthenticationMode
    /// `--ui-testing-seed-servers`: saves two unreachable servers, "Alpha" (signed in) and "Beta" (signed out).
    let seedsServers: Bool
    /// `--ui-testing-admin-gate=authorized`: a server's admin-access check passes without asking the server.
    let forcesAdminAccess: Bool
    /// `--ui-testing-open-url=bloemadmin://…`: the app starts with that link waiting, as if it had been
    /// opened from a notification, widget or shortcut.
    let openURL: URL?
    /// `--ui-testing-silo-server=plain|bloem|mixed`: saves signed-in servers answered inside the app (see
    /// `SiloServerUITestFixture`) and lets their admin check pass.
    let siloServer: SiloServerUITestFixture?

    var isUITesting: Bool {
        resetsPersistedState || authenticationMode != .system
    }

    init(arguments: [String]) {
        resetsPersistedState = arguments.contains("--ui-testing-reset")
        seedsServers = arguments.contains("--ui-testing-seed-servers")
        siloServer = arguments.first { $0.hasPrefix("--ui-testing-silo-server=") }
            .flatMap { SiloServerUITestFixture(rawValue: String($0.dropFirst("--ui-testing-silo-server=".count))) }
        forcesAdminAccess = arguments.contains("--ui-testing-admin-gate=authorized") || siloServer != nil
        openURL = arguments.first { $0.hasPrefix("--ui-testing-open-url=") }
            .flatMap { URL(string: String($0.dropFirst("--ui-testing-open-url=".count))) }
        authenticationMode = arguments.compactMap { argument -> AuthenticationMode? in
            switch argument {
            case "--ui-testing-auth=success":
                return .success
            case "--ui-testing-auth=unavailable":
                return .unavailable
            case "--ui-testing-auth=success-then-pending":
                return .successThenPending
            default:
                return nil
            }
        }.last ?? .system
    }

    @MainActor
    func makeAuthenticator() -> any BiometricAuthenticating {
        switch authenticationMode {
        case .system:
            LAContextAuthenticator()
        case .success, .unavailable, .successThenPending:
            DebugBiometricAuthenticator(mode: authenticationMode)
        }
    }

    /// The servers `--ui-testing-seed-servers` saves. Nothing listens on these addresses, so a page that
    /// loads from them shows its failure state quickly instead of waiting on the network.
    static let seededServers = [
        AdminServer(id: "ui-alpha", baseURL: URL(string: "https://127.0.0.1:9")!, displayName: "Alpha"),
        AdminServer(id: "ui-beta", baseURL: URL(string: "https://127.0.0.1:19")!, displayName: "Beta"),
    ]

    func seedServers(
        metadataStore: any ServerMetadataStoring,
        credentialStore: any CredentialStoring
    ) throws {
        if let siloServer {
            SiloServerUITestFixture.install()
            try metadataStore.saveServers(siloServer.servers)
            for server in siloServer.servers {
                try credentialStore.save(
                    ServerCredentials(version: ServerCredentials.currentVersion, accessToken: "ui-testing-token", refreshToken: nil),
                    for: server.id
                )
            }
            return
        }
        guard seedsServers else { return }
        try metadataStore.saveServers(Self.seededServers)
        try credentialStore.save(
            ServerCredentials(version: ServerCredentials.currentVersion, accessToken: "ui-testing-token", refreshToken: nil),
            for: "ui-alpha"
        )
    }

    /// Clears discoverable metadata before deleting credentials. If a later
    /// Keychain deletion fails, no orphaned credential remains reachable from
    /// the app's server list.
    func resetPersistedState(
        metadataStore: any ServerMetadataStoring,
        credentialStore: any CredentialStoring
    ) throws {
        guard resetsPersistedState else { return }
        let servers = try metadataStore.loadServers()
        try metadataStore.saveServers([])
        var firstDeletionError: Error?
        for server in servers {
            do {
                try credentialStore.deleteCredentials(for: server.id)
            } catch {
                if firstDeletionError == nil {
                    firstDeletionError = error
                }
            }
        }
        if let firstDeletionError {
            throw firstDeletionError
        }
    }
}

private struct DebugBiometricAuthenticator: BiometricAuthenticating {
    let mode: DebugLaunchConfiguration.AuthenticationMode
    private let attempts = DebugAuthenticationAttempts()

    func canAuthenticate() -> Bool {
        mode != .unavailable
    }

    func authenticate() async -> Bool {
        switch mode {
        case .system:
            return false
        case .success:
            return true
        case .unavailable:
            return false
        case .successThenPending:
            guard await attempts.isFirstAttempt() else {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                }
                return false
            }
            return true
        }
    }
}

private actor DebugAuthenticationAttempts {
    private var count = 0

    func isFirstAttempt() -> Bool {
        count += 1
        return count == 1
    }
}
#endif

/// Shared, per-scene local-authentication gate (Feature 2). Owns purely the
/// LOCK/UNLOCK state machine — the real `LAContext` prompt is delegated to
/// the injected `BiometricAuthenticating`, which is what makes this class
/// testable end-to-end with a mock, unlike the biometric prompt itself.
///
/// Policy (deliberately simple, per design brief — no grace-period timer):
/// - Starts locked (`startLocked: true` by default) — the app requires
///   unlocking once per launch before its content is usable.
/// - `handleScenePhaseChange(.background)` always re-locks that scene.
/// - `handleScenePhaseChange(.inactive)` ALSO re-locks that scene (review finding I2):
///   iOS snapshots the app around the resign-active/background transition
///   for the app-switcher preview (and its on-disk cache), and `.inactive`
///   is the phase that fires on that transition — briefly showing the
///   system UI (Control Center, an incoming call, Face ID's own overlay) or
///   backgrounding both pass through `.inactive` first. An app holding real
///   admin credentials that can administer any user must not let that
///   snapshot capture a live user list/stream sessions/quotas, so this
///   locks immediately rather than waiting for `.background`.
/// - Local Authentication can itself make a scene inactive. That transition
///   still shields the protected UI immediately, but it does not invalidate
///   the shared prompt unless the scene actually backgrounds. A successful
///   completion is accepted only after the scene is active again.
/// - A device without passcode/biometric authentication remains locked.
/// - Authentication completions only unlock while their originating attempt
///   is still current and the scene is active.
///
/// Note this class only decides LOCKED/UNLOCKED. The `WindowGroup` scene
/// root owns automatic prompting because it receives the authoritative
/// scene phase; the shield's lock screen only presents status and a manual
/// retry action.
@Observable
@MainActor
final class AppLockState {
    enum Availability: Equatable {
        case available
        case unavailable
    }

    private(set) var availability: Availability
    private let authenticator: BiometricAuthenticating
    private let protectedUI: ProtectedUISecuring
    private let startsLocked: Bool
    private var scenePhases: [AppSceneID: AppScenePhase] = [:]
    private var sceneLocks: [AppSceneID: Bool] = [:]
    private var unregisteredSceneIDs: Set<AppSceneID> = []
    private var authenticationAttemptID = 0
    private struct AuthenticationAttempt {
        let id: Int
        let ownerSceneID: AppSceneID
        var participantSceneIDs: Set<AppSceneID>
    }
    private struct CoalescedUnlockWaiter {
        let sceneID: AppSceneID
        let continuation: CheckedContinuation<Void, Never>
    }
    private var activeAuthenticationAttempt: AuthenticationAttempt?
    private var coalescedUnlockWaiters: [CoalescedUnlockWaiter] = []

    init(
        authenticator: BiometricAuthenticating = LAContextAuthenticator(),
        startLocked: Bool = true,
        protectedUI: ProtectedUISecuring = NoopProtectedUISecurer()
    ) {
        self.authenticator = authenticator
        self.startsLocked = startLocked
        self.protectedUI = protectedUI
        self.availability = authenticator.canAuthenticate() ? .available : .unavailable
    }

    func isLocked(for sceneID: AppSceneID) -> Bool {
        sceneLocks[sceneID] ?? startsLocked
    }

    /// Called from the app root's `.onChange(of: scenePhase)`. Pure
    /// state-transition logic — no SwiftUI/view-lifecycle dependency beyond
    /// the `ScenePhase` value itself, so this is directly unit-testable.
    func handleScenePhaseChange(_ phase: AppScenePhase, for sceneID: AppSceneID) {
        unregisteredSceneIDs.remove(sceneID)
        scenePhases[sceneID] = phase
        switch phase {
        case .background:
            sceneLocks[sceneID] = true
            protectedUI.secureForLock(sceneID: sceneID)
            if activeAuthenticationAttempt?.ownerSceneID == sceneID {
                invalidateAuthenticationAttempt()
            } else {
                removeParticipant(sceneID)
            }
        case .inactive:
            sceneLocks[sceneID] = true
            protectedUI.secureForLock(sceneID: sceneID)
            // Local Authentication makes its owning scene inactive while the
            // system prompt is presented. Preserve only that owner; any
            // coalesced scene that resigns active must remain shielded.
            if activeAuthenticationAttempt?.ownerSceneID != sceneID {
                removeParticipant(sceneID)
            }
        case .active:
            availability = authenticator.canAuthenticate() ? .available : .unavailable
        }
    }

    /// Automatic prompts must use the scene phase observed by SwiftUI rather
    /// than this state's launch default. Synchronizing here closes the
    /// first-mount race even if the view task runs before the app root's
    /// initial scene-phase callback.
    func automaticallyUnlock(for observedScenePhase: AppScenePhase, sceneID: AppSceneID) async {
        handleScenePhaseChange(observedScenePhase, for: sceneID)
        guard observedScenePhase == .active else { return }
        await unlock(for: sceneID)
    }

    /// The lock screen's "Unlock" button action.
    func unlock(for sceneID: AppSceneID) async {
        // A WindowGroup can disappear after its root schedules an automatic
        // unlock but before that task enters this actor. Never let that stale
        // task start or join an authentication attempt for surviving scenes.
        guard !unregisteredSceneIDs.contains(sceneID) else { return }
        guard phase(for: sceneID) == .active else {
            sceneLocks[sceneID] = true
            return
        }
        if activeAuthenticationAttempt != nil {
            activeAuthenticationAttempt?.participantSceneIDs.insert(sceneID)
            await withCheckedContinuation { continuation in
                coalescedUnlockWaiters.append(
                    CoalescedUnlockWaiter(sceneID: sceneID, continuation: continuation)
                )
            }
            return
        }
        guard authenticator.canAuthenticate() else {
            availability = .unavailable
            sceneLocks[sceneID] = true
            return
        }
        availability = .available

        authenticationAttemptID += 1
        let attemptID = authenticationAttemptID
        activeAuthenticationAttempt = AuthenticationAttempt(
            id: attemptID,
            ownerSceneID: sceneID,
            participantSceneIDs: [sceneID]
        )
        let succeeded = await authenticator.authenticate()
        completeAuthenticationAttempt(attemptID, succeeded: succeeded)
    }

    /// Removes lifecycle state for a destroyed scene and prevents an
    /// in-flight prompt owned by that scene from affecting surviving windows.
    func unregisterScene(_ sceneID: AppSceneID) {
        unregisteredSceneIDs.insert(sceneID)
        scenePhases.removeValue(forKey: sceneID)
        sceneLocks.removeValue(forKey: sceneID)
        if activeAuthenticationAttempt?.ownerSceneID == sceneID {
            invalidateAuthenticationAttempt()
        } else {
            removeParticipant(sceneID)
        }
    }

    private func completeAuthenticationAttempt(_ attemptID: Int, succeeded: Bool) {
        guard let attempt = activeAuthenticationAttempt,
              attempt.id == attemptID else { return }
        activeAuthenticationAttempt = nil

        if succeeded,
           attemptID == authenticationAttemptID,
           phase(for: attempt.ownerSceneID) == .active {
            for sceneID in attempt.participantSceneIDs where phase(for: sceneID) == .active {
                sceneLocks[sceneID] = false
            }
        }
        resumeCoalescedUnlockWaiters()
    }

    private func invalidateAuthenticationAttempt() {
        authenticationAttemptID += 1
        activeAuthenticationAttempt = nil
        resumeCoalescedUnlockWaiters()
    }

    private func removeParticipant(_ sceneID: AppSceneID) {
        activeAuthenticationAttempt?.participantSceneIDs.remove(sceneID)
        let removedWaiters = coalescedUnlockWaiters.filter { $0.sceneID == sceneID }
        coalescedUnlockWaiters.removeAll { $0.sceneID == sceneID }
        removedWaiters.forEach { $0.continuation.resume() }
    }

    private func phase(for sceneID: AppSceneID) -> AppScenePhase {
        scenePhases[sceneID] ?? .active
    }

    private func resumeCoalescedUnlockWaiters() {
        let waiters = coalescedUnlockWaiters
        coalescedUnlockWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }
}

/// Mirrors SwiftUI's `ScenePhase` with the exact three cases this app cares
/// about, so `AppLockState.handleScenePhaseChange` (and its tests) don't
/// need to import SwiftUI or construct a real `ScenePhase` (which has no
/// public initializer). The app root and lock screen convert the real phase
/// at their scene-lifecycle boundaries.
enum AppScenePhase: Equatable {
    case active
    case inactive
    case background
}
