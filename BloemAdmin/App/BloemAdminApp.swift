import SwiftUI
import UIKit

@main
@MainActor
struct BloemAdminApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let protectedUI = ApplicationProtectedUISecurer.shared
    @State private var lockState: AppLockState

    init() {
        BloemUIKitAppearance.apply()
#if DEBUG
        let launchConfiguration = DebugLaunchConfiguration(
            arguments: ProcessInfo.processInfo.arguments
        )
        let metadataStore = UserDefaultsServerMetadataStore(defaults: .standard)
        let credentialStore = KeychainCredentialStore()
        try? launchConfiguration.resetPersistedState(
            metadataStore: metadataStore,
            credentialStore: credentialStore
        )
        if launchConfiguration.resetsPersistedState {
            ShellScopePreferences().reset()
        }
        try? launchConfiguration.seedServers(
            metadataStore: metadataStore,
            credentialStore: credentialStore
        )
        AdminGateViewModel.forcesAuthorizedForUITests = launchConfiguration.forcesAdminAccess
        if let url = launchConfiguration.openURL { DeepLinkCenter.shared.receive(url) }
        _lockState = State(
            initialValue: AppLockState(
                authenticator: launchConfiguration.makeAuthenticator(),
                protectedUI: ApplicationProtectedUISecurer.shared
            )
        )
#else
        _lockState = State(
            initialValue: AppLockState(protectedUI: ApplicationProtectedUISecurer.shared)
        )
#endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if let variant = DashboardUITestFixture.requested(ProcessInfo.processInfo.arguments) {
                    DashboardFixtureRoot(variant: variant)
                } else if ProcessInfo.processInfo.arguments.contains(StreamRowFixtureView.launchArgument) {
                    StreamRowFixtureView()
                } else {
                    ProtectedSceneRoot(lockState: lockState, protectedUI: protectedUI)
                }
#else
                ProtectedSceneRoot(lockState: lockState, protectedUI: protectedUI)
#endif
            }
            .bloemAppearance()
        }
    }
}

private struct ProtectedSceneRoot: View {
    let lockState: AppLockState
    let protectedUI: ApplicationProtectedUISecurer
    @State private var sceneID = AppSceneID()
    @Environment(\.scenePhase) private var scenePhase

    /// The app's root. Debug builds started by a UI test open that test's fixture instead: the User page over
    /// a stub server, the organization pages (see `OrganizationUITestHost`), or Platform › Organizations (see
    /// `PlatformOrganizationsUITestHost`).
    @ViewBuilder
    private var rootContent: some View {
#if DEBUG
        if UserPageUITestFixture.isRequested {
            UserPageUITestRoot()
        } else if IncidentUITestFixture.isRequested {
            IncidentUITestRoot()
        } else if LibrariesUITestFixture.isRequested {
            LibrariesUITestRoot()
        } else if let page = AutomationUITestFixture.requested {
            AutomationUITestRoot(page: page)
        } else if SettingsUITestFixture.isRequested {
            SettingsUITestRoot()
        } else if PlatformOrganizationsUITestFixture.isRequested {
            PlatformOrganizationsUITestHost()
        } else if let scenario = OrganizationUITestScenario.current {
            OrganizationUITestHost(scenario: scenario)
        } else if SiloLiveUITestFixture.isRequested {
            SiloLiveSeedRoot()
        } else if SiloServerUITestFixture.requested != nil {
            AppRootView().overlay(alignment: .topLeading) { SiloFixtureRequestProbe() }
        } else {
            AppRootView()
        }
#else
        AppRootView()
#endif
    }

    var body: some View {
        let isLocked = lockState.isLocked(for: sceneID)
        ZStack {
            rootContent
                .environment(\.appIsLocked, isLocked)
                .disabled(isLocked)
                .allowsHitTesting(!isLocked)
                .accessibilityHidden(isLocked)

            if isLocked {
                // Fallback coverage for the short interval before the
                // scene-level shield window attaches. Automatic prompting
                // remains owned by this scene root; both lock screens only
                // expose a manual retry action.
                LockScreenView(
                    lockState: lockState,
                    sceneID: sceneID,
                    automaticallyAuthenticates: false
                )
            }

            AppLockShieldInstaller(
                lockState: lockState,
                sceneID: sceneID,
                protectedUI: protectedUI
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        // A bloemadmin:// link waits in DeepLinkCenter until the lock is open (see DeepLinkHandling).
        .onOpenURL { DeepLinkCenter.shared.receive($0) }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            // Every live connection follows the scenes: open while one is active, closed 10 s after none is.
            LiveHub.shared.sceneChanged(sceneID, phase: newPhase.asAppScenePhase)
            lockState.handleScenePhaseChange(newPhase.asAppScenePhase, for: sceneID)
            guard newPhase == .active, lockState.isLocked(for: sceneID) else { return }
            // The scene root owns automatic authentication because its
            // ScenePhase environment comes from WindowGroup. A hosting
            // controller in the separate shield UIWindow does not reliably
            // receive that scene lifecycle value.
            Task {
                await lockState.unlock(for: sceneID)
            }
        }
    }
}

@MainActor
protocol SceneProtectedUIShielding: AnyObject {
    var sceneID: AppSceneID { get }
    func secureForLock()
}

/// Fans the synchronous lock action out to every mounted `WindowGroup` scene.
/// The injectable end-editing closure is the deterministic test seam for
/// clearing an active text-field responder before snapshotting.
@MainActor
final class ApplicationProtectedUISecurer: ProtectedUISecuring {
    static let shared = ApplicationProtectedUISecurer()

    private struct WeakShield {
        weak var value: SceneProtectedUIShielding?
    }

    private let endEditing: () -> Void
    private var shields: [WeakShield] = []

    init(endEditing: (() -> Void)? = nil) {
        self.endEditing = endEditing ?? {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }

    func register(_ shield: SceneProtectedUIShielding) {
        removeReleasedShields()
        guard !shields.contains(where: { $0.value === shield }) else { return }
        shields.append(WeakShield(value: shield))
    }

    func unregister(_ shield: SceneProtectedUIShielding) {
        shields.removeAll { $0.value == nil || $0.value === shield }
    }

    func secureForLock(sceneID: AppSceneID) {
        endEditing()
        removeReleasedShields()
        shields
            .compactMap(\.value)
            .filter { $0.sceneID == sceneID }
            .forEach { $0.secureForLock() }
    }

    private func removeReleasedShields() {
        shields.removeAll { $0.value == nil }
    }
}

/// Installs a dedicated high-level `UIWindow` in the current `WindowGroup`
/// scene. Unlike a SwiftUI overlay, this window sits above sheets, alerts, and
/// confirmation dialogs hosted by the application's normal content window.
private struct AppLockShieldInstaller: UIViewRepresentable {
    let lockState: AppLockState
    let sceneID: AppSceneID
    let protectedUI: ApplicationProtectedUISecurer

    func makeCoordinator() -> Coordinator {
        Coordinator(lockState: lockState, sceneID: sceneID, protectedUI: protectedUI)
    }

    func makeUIView(context: Context) -> SceneAttachmentView {
        let view = SceneAttachmentView()
        view.isUserInteractionEnabled = false
        view.onWindowSceneChange = { [weak coordinator = context.coordinator] scene in
            coordinator?.attach(to: scene)
        }
        return view
    }

    func updateUIView(_ uiView: SceneAttachmentView, context: Context) {
        context.coordinator.attach(to: uiView.window?.windowScene)
        context.coordinator.update(isLocked: lockState.isLocked(for: sceneID))
    }

    static func dismantleUIView(_ uiView: SceneAttachmentView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, SceneProtectedUIShielding {
        private let lockState: AppLockState
        let sceneID: AppSceneID
        private let protectedUI: ApplicationProtectedUISecurer
        private weak var windowScene: UIWindowScene?
        private weak var previousKeyWindow: UIWindow?
        private var shieldWindow: UIWindow?

        init(
            lockState: AppLockState,
            sceneID: AppSceneID,
            protectedUI: ApplicationProtectedUISecurer
        ) {
            self.lockState = lockState
            self.sceneID = sceneID
            self.protectedUI = protectedUI
            super.init()
            protectedUI.register(self)
        }

        func attach(to scene: UIWindowScene?) {
            guard let scene else { return }
            guard windowScene !== scene || shieldWindow == nil else { return }

            hideShield()
            shieldWindow = nil
            windowScene = scene

            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.backgroundColor = UIColor(Theme.background)
            window.overrideUserInterfaceStyle = AppearancePreference.stored().interfaceStyle

            let host = UIHostingController(
                rootView: LockScreenView(
                    lockState: lockState,
                    sceneID: sceneID,
                    automaticallyAuthenticates: false
                )
                .tint(Theme.text)
                .bloemFont(.bodyLarge)
            )
            host.view.backgroundColor = UIColor(Theme.background)
            host.view.accessibilityViewIsModal = true
            window.rootViewController = host
            window.isHidden = true
            shieldWindow = window

            update(isLocked: lockState.isLocked(for: sceneID))
        }

        func update(isLocked: Bool) {
            if isLocked {
                showShield()
            } else {
                hideShield()
            }
        }

        func secureForLock() {
            windowScene?.windows
                .filter { $0 !== shieldWindow }
                .forEach { $0.endEditing(true) }
            showShield()
        }

        func detach() {
            hideShield()
            shieldWindow = nil
            windowScene = nil
            protectedUI.unregister(self)
            lockState.unregisterScene(sceneID)
        }

        private func showShield() {
            guard let window = shieldWindow else { return }
            if window.isHidden {
                previousKeyWindow = windowScene?.windows.first {
                    $0.isKeyWindow && $0 !== window
                }
            }
            window.isHidden = false
            window.makeKey()
            UIAccessibility.post(notification: .screenChanged, argument: window.rootViewController?.view)
        }

        private func hideShield() {
            guard let window = shieldWindow, !window.isHidden else { return }
            window.isHidden = true
            previousKeyWindow?.makeKey()
            previousKeyWindow = nil
        }
    }
}

private final class SceneAttachmentView: UIView {
    var onWindowSceneChange: ((UIWindowScene?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowSceneChange?(window?.windowScene)
    }
}

extension ScenePhase {
    /// Converts SwiftUI's `ScenePhase` to `AppScenePhase`, the plain enum
    /// `AppLockState.handleScenePhaseChange` actually takes — see that
    /// type's doc comment for why the conversion lives here instead of
    /// `AppLockState` depending on SwiftUI directly.
    var asAppScenePhase: AppScenePhase {
        switch self {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .inactive
        }
    }
}
