import SwiftUI
import UIKit

/// The few pieces of chrome SwiftUI draws through UIKit, set in the app's typeface and colours: navigation
/// titles and bar buttons, segmented controls and text fields. (An alert, a confirmation dialog and the share
/// sheet are the system's own; iOS gives an app no way to restyle them, so they keep the system font.)
@MainActor
enum BloemUIKitAppearance {
    static func apply() {
        let text = UIColor(Theme.text)
        let muted = UIColor(Theme.muted)

        let bar = UINavigationBarAppearance()
        bar.configureWithTransparentBackground()
        bar.titleTextAttributes = [.font: BloemFont.uiFont(.titleMedium), .foregroundColor: text]
        bar.largeTitleTextAttributes = [.font: BloemFont.uiFont(.headlineLarge), .foregroundColor: text]
        let button = UIBarButtonItemAppearance(style: .plain)
        button.normal.titleTextAttributes = [.font: BloemFont.uiFont(.titleSmall), .foregroundColor: text]
        button.highlighted.titleTextAttributes = [.font: BloemFont.uiFont(.titleSmall), .foregroundColor: muted]
        bar.buttonAppearance = button
        bar.doneButtonAppearance = button
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar

        // A segmented control is the raised surface with the chosen segment on the `selected` surface in text colour,
        // never an accent fill or outline (maintainer, 2026-11-16). The system keeps the shape of the control itself.
        let segmentedNormal: [NSAttributedString.Key: Any] = [.font: BloemFont.uiFont(.labelLarge), .foregroundColor: muted]
        let segmentedSelected: [NSAttributedString.Key: Any] = [.font: BloemFont.uiFont(.labelLarge), .foregroundColor: text]
        UISegmentedControl.appearance().setTitleTextAttributes(segmentedNormal, for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes(segmentedSelected, for: .selected)
        UISegmentedControl.appearance().backgroundColor = UIColor(Theme.raised)
        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(Theme.selected)

        UITextField.appearance().font = BloemFont.uiFont(.bodyLarge)
        UITextView.appearance().font = BloemFont.uiFont(.bodyLarge)
        UILabel.appearance(whenContainedInInstancesOf: [UITableViewHeaderFooterView.self]).font = BloemFont.uiFont(.labelMedium)
    }
}
