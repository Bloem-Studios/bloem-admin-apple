import Foundation
import WidgetKit

/// Copies the two app settings the widgets honour into the App Group: "Show details on the lock screen"
/// (this device) and the Appearance choice. Written whenever either changes and when the app comes to the
/// foreground; the widgets reload afterwards.
enum WidgetSettingsSync {
    static func current(defaults: UserDefaults = .standard) -> WidgetSettings {
        WidgetSettings(
            showDetailsOnLockScreen: AlertPreferences(defaults: defaults).showsDetails,
            appearance: AppearancePreference.stored(in: defaults).rawValue
        )
    }

    static func write(
        defaults: UserDefaults = .standard,
        store: (any WidgetSettingsStoring)? = FileWidgetSettingsStore.appGroup(),
        reloader: any WidgetTimelineReloading = SystemWidgetReloader()
    ) {
        // The notification extension reads the same choice from its own small file.
        if defaults === UserDefaults.standard {
            PushSettingsMirror.sync(showsDetails: AlertPreferences(defaults: defaults).showsDetails)
        }
        guard let store else { return }
        let settings = current(defaults: defaults)
        guard store.load() != settings else { return }
        try? store.save(settings)
        reloader.reloadAll()
    }
}
