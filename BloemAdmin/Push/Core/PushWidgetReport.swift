import Foundation

// Widget wakes (bloem-staff-widgets.md, "Widget wakes"). Widgets never open sockets. A server that has been told
// this phone has widgets placed sends a silent push (the relay's `background_wake`) when something a widget
// shows changed, and the app re-reads through its normal REST API. What the phone tells the server is below.

/// What a placed widget shows, in the server's words (`widget_channels`). A wake names the channels that changed.
enum WidgetChannel: String, CaseIterable, Codable, Comparable, Sendable {
    case sessions
    case requests
    case libraries
    case nodes

    static func < (lhs: WidgetChannel, rhs: WidgetChannel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whether this phone has a widget placed, and which channels the placed widgets show. Kept in the push
/// registration, so the server holds the same answer; sent whenever it differs from what the server holds.
struct WidgetReport: Codable, Equatable, Sendable {
    var placed: Bool
    /// Sorted, with no repeats; empty when nothing is placed.
    var channels: [WidgetChannel]

    init(placed: Bool, channels: Set<WidgetChannel>) {
        self.placed = placed && !channels.isEmpty
        self.channels = self.placed ? channels.sorted() : []
    }

    /// No widget placed. (Not named `none`: written as `.none` where an optional is expected, that would silently
    /// mean `nil`, "unknown".)
    static let nothingPlaced = WidgetReport(placed: false, channels: [])

    var channelNames: [String] { channels.map(\.rawValue) }
}

/// A wake as the server names it: the delivery id after the device id is
/// `widgets-{channel}[-{channel}...]-{unix seconds}`, for example `widgets-nodes-requests-1763254800`. The channels
/// are sorted whole names with no hyphen inside one. A wake has no content row, so nothing is fetched.
struct WidgetWake: Equatable, Sendable {
    static let reason = "widgets"

    /// The channels that changed and this build knows. A channel it does not know is dropped, so a newer server
    /// can add one without this build misreading the wake.
    let channels: Set<WidgetChannel>
    let sentAt: Date

    /// nil for anything that is not a well-formed wake.
    init?(deliveryID: String) {
        let parts = deliveryID.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == Self.reason,
              let seconds = Double(parts[parts.count - 1]), parts[parts.count - 1].allSatisfy(\.isNumber) else { return nil }
        let names = parts[1..<(parts.count - 1)]
        guard names.allSatisfy({ !$0.isEmpty }) else { return nil }
        channels = Set(names.compactMap(WidgetChannel.init(rawValue:)))
        sentAt = Date(timeIntervalSince1970: seconds)
    }

    init?(wire: PushWire) {
        self.init(deliveryID: wire.deliveryID)
    }
}
