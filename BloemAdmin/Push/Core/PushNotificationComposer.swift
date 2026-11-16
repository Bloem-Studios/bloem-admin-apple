import Foundation
import UserNotifications

// Turns a push into what the phone shows. The relay's notification says nothing but a generic line (it never
// sees text), and `mutable-content` lets the extension replace it with what the app's own server says.
// The privacy rule is here and nowhere else: unless "Show details on the lock screen" is on, a notification
// carries only the server's lock-screen text, with no name, title, count or server name in it.

enum PushCategoryID {
    /// A request waiting: Approve and Decline.
    static let request = "bloem.admin.push.request"
    /// Everything else.
    static let general = "bloem.admin.push.general"
}

enum PushActionID {
    static let approve = "bloem.admin.push.approve"
    static let decline = "bloem.admin.push.decline"
}

/// The keys of a notification's `userInfo`. `serverID` is the key the local server alerts already use.
enum PushUserInfo {
    static let marker = "bloemPush"
    static let serverID = "serverID"
    static let kind = "kind"
    static let page = "page"
    static let itemID = "itemID"
}

/// What the phone shows for one push.
struct PushNotificationPlan: Equatable, Sendable {
    var title: String
    var subtitle: String
    var body: String
    var threadIdentifier: String
    var categoryIdentifier: String
    /// Identifiers only, never a name: a tap uses them to open the right place.
    var userInfo: [String: String]

    func apply(to content: UNMutableNotificationContent) {
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.threadIdentifier = threadIdentifier
        content.categoryIdentifier = categoryIdentifier
        // The push's own keys (aps, the delivery id) stay.
        var merged = content.userInfo
        for (key, value) in userInfo { merged[key] = value }
        content.userInfo = merged
    }
}

enum PushNotificationComposer {
    static var genericTitle: String { String(localized: "New notification") }
    static var genericBody: String { String(localized: "Open the app to see it") }

    /// The thread of a notification whose kind is not known (the text could not be read).
    static let unknownThread = "admin.push"

    /// - Parameters:
    ///   - registration: the saved server the push is for; nil when the device id is not one of this phone's
    ///     live registrations, or the shared keychain cannot be read yet.
    ///   - display: the cleaned text; nil when the server could not be asked.
    static func compose(registration: PushRegistration?, display: PushDisplay?, showsDetails: Bool) -> PushNotificationPlan {
        var userInfo = [PushUserInfo.marker: "1"]
        guard let registration else {
            return PushNotificationPlan(
                title: genericTitle, subtitle: "", body: genericBody,
                threadIdentifier: unknownThread, categoryIdentifier: PushCategoryID.general, userInfo: userInfo
            )
        }
        userInfo[PushUserInfo.serverID] = registration.serverID
        let serverName = showsDetails ? registration.serverName : ""
        guard let display else {
            return PushNotificationPlan(
                title: genericTitle, subtitle: serverName, body: genericBody,
                threadIdentifier: "\(registration.serverID).\(unknownThread)",
                categoryIdentifier: PushCategoryID.general, userInfo: userInfo
            )
        }
        userInfo[PushUserInfo.kind] = display.kind.rawValue
        if let page = display.page { userInfo[PushUserInfo.page] = page.rawValue }
        if let item = display.itemID { userInfo[PushUserInfo.itemID] = item }
        // Both buttons or none: a category cannot show half of its actions.
        let offersButtons = display.kind == .requestWaiting && display.itemID != nil
            && Set(display.actions) == [.approve, .decline]
        return PushNotificationPlan(
            title: showsDetails ? display.title : display.lockScreen,
            subtitle: serverName,
            body: showsDetails ? display.body : "",
            threadIdentifier: display.kind.threadIdentifier(serverID: registration.serverID),
            categoryIdentifier: offersButtons ? PushCategoryID.request : PushCategoryID.general,
            userInfo: userInfo
        )
    }
}

/// Reads a push, asks the app's own server for its text and decides what to show. The extension is a thin
/// shell around this, so everything it does is tested without one.
struct PushNotificationProcessor: Sendable {
    /// Well inside what iOS gives an extension (about thirty seconds).
    static let defaultFetchBudget: Duration = .seconds(8)

    let registrations: any PushRegistrationStoring
    let settings: any PushSharedSettingsStoring
    let api: any PushDisplayAPI
    var fetchBudget: Duration = PushNotificationProcessor.defaultFetchBudget

    func plan(for wire: PushWire?) async -> PushNotificationPlan {
        let showsDetails = settings.load().showDetailsOnLockScreen
        guard let wire, let registration = registrations.registration(deviceID: wire.deviceID) else {
            return PushNotificationComposer.compose(registration: nil, display: nil, showsDetails: showsDetails)
        }
        let api = api
        let result = await PushBoundedWait.run(fetchBudget) { () async -> PushContentResult? in
            await api.content(baseURL: registration.baseURL, displayToken: registration.displayToken, contentID: wire.contentID)
        }
        var display: PushDisplay?
        if case .content(let content)? = result { display = content.sanitized() }
        return PushNotificationComposer.compose(registration: registration, display: display, showsDetails: showsDetails)
    }
}
