import SwiftUI

/// Covers one scene's mounted content whenever `AppLockState` locks it —
/// on first launch and every time the app returns from the
/// background/inactive state. See `AppLockState`'s doc comment for the full
/// lock/unlock policy.
///
/// Automatic prompting is normally owned by the `WindowGroup` scene root,
/// whose `scenePhase` is authoritative. The optional automatic behavior here
/// remains a reusable fallback for lock screens mounted directly in that
/// environment; shield-window instances disable it and retain only manual
/// retry behavior.
struct LockScreenView: View {
    let lockState: AppLockState
    let sceneID: AppSceneID
    var automaticallyAuthenticates = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            VStack(spacing: Theme.Space.xl) {
                // The app's own mark, the one the widgets carry: the tulip with the admin app's server badge.
                Image("bloem.admin-mark")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.bloemText)
                    // Purely decorative — the heading and body text right below
                    // already say what this screen is; without this VoiceOver
                    // would announce a redundant, unlabeled image.
                    .accessibilityHidden(true)
                // The same layout and words in every staff app: mark, "<app> is locked", one line, one accent button.
                Text("Bloem Admin is locked")
                    .bloemText(.headlineSmall)
                    .multilineTextAlignment(.center)
                Text(message)
                    .bloemText(.bodyMedium)
                    .foregroundStyle(.bloemMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.xl)
                Button(lockState.availability == .available ? String(localized: "Unlock") : String(localized: "Try again")) {
                    Task { await lockState.unlock(for: sceneID) }
                }
                .buttonStyle(.bloemProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Attempt automatically on first appearance. The observed environment
        // phase is passed through so an inactive/background first mount cannot
        // rely on AppLockState's default `.active` value and raise a prompt.
        .task {
            guard automaticallyAuthenticates else { return }
            await lockState.automaticallyUnlock(
                for: scenePhase.asAppScenePhase,
                sceneID: sceneID
            )
        }
        // Re-attempts on every subsequent return to `.active` (app
        // foregrounded again after `.inactive`/`.background`) — this is
        // what actually delivers "re-prompt on foreground," since `.task`
        // alone only covers the very first appearance. The button above
        // still remains for a manual retry after a failed/cancelled
        // attempt.
        .onChange(of: scenePhase) { _, newPhase in
            guard automaticallyAuthenticates, newPhase == .active else { return }
            Task {
                await lockState.automaticallyUnlock(
                    for: newPhase.asAppScenePhase,
                    sceneID: sceneID
                )
            }
        }
    }

    private var message: String {
        switch lockState.availability {
        case .available:
            String(localized: "Unlock with Face ID, Touch ID or your passcode.")
        case .unavailable:
            String(localized: "Turn on a passcode, Face ID or Touch ID in Settings to use Bloem Admin.")
        }
    }
}
