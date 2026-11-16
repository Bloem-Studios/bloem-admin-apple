import Foundation
import UserNotifications

/// What the person did with a notification, and what the app does about it.
enum PushResponse: Equatable, Sendable {
    /// A tap: open that server, and the page and item the notification names, after the app lock.
    case open(DeepLinkRoute)
    /// Approve or Decline on a request notification.
    case decide(serverID: String, requestID: String, approve: Bool)
    case ignore

    static func interpret(actionIdentifier: String, info: PushTapInfo) -> PushResponse {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            return info.route.map(PushResponse.open) ?? .ignore
        case PushActionID.approve, PushActionID.decline:
            // Only a request notice that names its server and its request can be answered.
            guard info.kind == .requestWaiting, let serverID = info.serverID, let requestID = info.itemID else { return .ignore }
            return .decide(serverID: serverID, requestID: requestID, approve: actionIdentifier == PushActionID.approve)
        default:
            return .ignore
        }
    }
}

enum PushDecisionOutcome: Equatable, Sendable {
    case done
    /// Someone else answered first (or withdrew it): nothing is waiting any more, which is what the
    /// administrator wanted to know.
    case alreadyHandled
    case failed
}

protocol PushRequestDeciding: Sendable {
    func decide(serverID: String, requestID: String, approve: Bool) async -> PushDecisionOutcome
}

/// A notification the app posts itself.
struct PushLocalNote: Equatable, Sendable {
    var identifier: String
    var title: String
    var threadIdentifier: String
    var userInfo: [String: String]
}

protocol PushLocalNotifying: Sendable {
    func post(_ note: PushLocalNote) async
    func removeDelivered(identifiers: [String]) async
}

struct SystemPushNotifier: PushLocalNotifying {
    func post(_ note: PushLocalNote) async {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.threadIdentifier = note.threadIdentifier
        content.categoryIdentifier = PushCategoryID.general
        content.userInfo = note.userInfo
        content.interruptionLevel = .active
        // The same identifier replaces the notification it answers.
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: note.identifier, content: content, trigger: nil))
    }

    func removeDelivered(identifiers: [String]) async {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Runs a notification's Approve or Decline. It calls the same route the widgets do. Success, and "already
/// handled", take the notification away. A failure replaces it with "Couldn't approve, open the app" (or
/// "decline"), which opens the request. Nothing destructive is ever offered.
struct PushActionRunner: Sendable {
    /// iOS gives a background action about thirty seconds; the answer must come well inside it.
    static let defaultBudget: Duration = .seconds(20)

    let decider: any PushRequestDeciding
    let notifier: any PushLocalNotifying
    var afterAnswer: @Sendable () -> Void = {}
    var budget: Duration = PushActionRunner.defaultBudget

    static func failureTitle(approve: Bool) -> String {
        approve ? String(localized: "Couldn't approve, open the app") : String(localized: "Couldn't decline, open the app")
    }

    func run(serverID: String, requestID: String, approve: Bool, notificationIdentifier: String) async {
        let decider = decider
        let outcome = await PushBoundedWait.run(budget) { () async -> PushDecisionOutcome? in
            await decider.decide(serverID: serverID, requestID: requestID, approve: approve)
        } ?? .failed
        switch outcome {
        case .done, .alreadyHandled:
            await notifier.removeDelivered(identifiers: [notificationIdentifier])
            afterAnswer()
        case .failed:
            await notifier.post(PushLocalNote(
                identifier: notificationIdentifier,
                title: Self.failureTitle(approve: approve),
                threadIdentifier: PushKind.requestWaiting.threadIdentifier(serverID: serverID),
                userInfo: [
                    PushUserInfo.marker: "1", PushUserInfo.serverID: serverID, PushUserInfo.kind: PushKind.requestWaiting.rawValue,
                    PushUserInfo.page: PushLinkPage.requests.rawValue, PushUserInfo.itemID: requestID,
                ]
            ))
        }
    }
}

/// The real decider: the widgets' client, which reads the app's sign-in from the shared keychain mirror and
/// renews it under the cross-process lock. The phone is unlocked (the action requires it), so the mirror is
/// readable.
struct WidgetRequestDecider: PushRequestDeciding {
    let fetcher: WidgetFetcher?
    let servers: @Sendable () -> [AdminServer]

    func decide(serverID: String, requestID: String, approve: Bool) async -> PushDecisionOutcome {
        // Exactly this server: an id that is not saved must never fall back to another server.
        guard let fetcher, let saved = servers().first(where: { $0.id == serverID }) else { return .failed }
        let server = WidgetServer(id: saved.id, name: saved.displayName, origin: saved.baseURL)
        let action: WidgetRequestAction = approve ? .approve : .decline
        let outcome = await fetcher.call(server: server) { api -> PushDecisionOutcome in
            do {
                try await api.act(on: requestID, action)
                return .done
            } catch let error as WidgetAPIError where error.status == 404 || error.status == 409 {
                return .alreadyHandled
            }
        }
        if case .success(let result) = outcome { return result }
        return .failed
    }
}
