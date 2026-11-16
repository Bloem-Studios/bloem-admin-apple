import Foundation

// The one app setting the notification service extension honours, copied by the app into a small file in the
// App Group. The extension cannot read the app's UserDefaults, and "Show details on the lock screen" decides
// whether it may put names and titles into a notification.

enum PushGroup {
    /// The App Group the app, its widgets and the extension share.
    static let identifier = "group.com.bloemstudios.admin"

    /// The shared container, or nil when the App Group is not available to this process (a build whose
    /// signing does not carry the entitlement).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// `push-settings.json`. Missing, unreadable or from another version means the most private choice: details off.
struct PushSharedSettings: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = PushSharedSettings.currentVersion
    /// The existing per-device "Show details on the lock screen" setting (App settings, Server alerts).
    var showDetailsOnLockScreen = false
}

protocol PushSharedSettingsStoring: Sendable {
    func load() -> PushSharedSettings
    func save(_ settings: PushSharedSettings) throws
}

struct FilePushSharedSettingsStore: PushSharedSettingsStoring {
    static let fileName = "push-settings.json"

    let directory: URL

    static func appGroup() -> FilePushSharedSettingsStore? {
        PushGroup.containerURL.map { FilePushSharedSettingsStore(directory: $0) }
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func load() -> PushSharedSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(PushSharedSettings.self, from: data),
              settings.version == PushSharedSettings.currentVersion
        else { return PushSharedSettings() }
        return settings
    }

    func save(_ settings: PushSharedSettings) throws {
        let data = try JSONEncoder().encode(settings)
        // Readable after the first unlock: the extension runs while the phone is locked.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The settings of a process that cannot reach the App Group: the most private choice, and nothing saved.
struct PrivatePushSettings: PushSharedSettingsStoring {
    func load() -> PushSharedSettings { PushSharedSettings() }
    func save(_ settings: PushSharedSettings) throws {}
}

/// Keeps `push-settings.json` in step with the app's "Show details on the lock screen" setting.
enum PushSettingsMirror {
    static func sync(
        showsDetails: Bool, store: (any PushSharedSettingsStoring)? = FilePushSharedSettingsStore.appGroup()
    ) {
        guard let store else { return }
        let settings = PushSharedSettings(showDetailsOnLockScreen: showsDetails)
        guard store.load() != settings else { return }
        try? store.save(settings)
    }
}
