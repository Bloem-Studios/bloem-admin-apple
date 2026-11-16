import SwiftUI
import UIKit

/// Which appearance the app uses: the system's, or one chosen in App settings.
enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    /// The `UserDefaults` key the choice is stored under.
    static let storageKey = "appearancePreference"

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// The stored choice; anything unreadable is the system appearance.
    static func stored(in defaults: UserDefaults = .standard) -> AppearancePreference {
        defaults.string(forKey: storageKey).flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }
}

/// Applies the chosen appearance to the whole app, including sheets, alerts and the lock shield window,
/// which SwiftUI's own `preferredColorScheme` does not always reach.
private struct AppearanceModifier: ViewModifier {
    @AppStorage(AppearancePreference.storageKey) private var raw = AppearancePreference.system.rawValue

    private var preference: AppearancePreference { AppearancePreference(rawValue: raw) ?? .system }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preference.colorScheme)
            // Text buttons and bars take the text colour; the accent is the primary action, the selection and
            // the switch that is on (set explicitly below), nothing else.
            .tint(Theme.text)
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
            .bloemFont(.bodyLarge)
            // Lists and forms draw graphite instead of the system grouped background.
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .onChange(of: raw, initial: true) { _, _ in applyToWindows() }
    }

    private func applyToWindows() {
        let style = preference.interfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

extension View {
    /// The app's appearance (System, Light or Dark) and accent, applied once at the root.
    func bloemAppearance() -> some View { modifier(AppearanceModifier()) }
}
