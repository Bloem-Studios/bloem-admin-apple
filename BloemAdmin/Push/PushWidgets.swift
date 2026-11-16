import Foundation
import WidgetKit

// Widget wakes, the app's half (bloem-staff-widgets.md, "Widget wakes"). Which widgets are placed is read from
// WidgetKit and reported to every server that can push; a silent push (`background_wake`) from such a server
// names the channels that changed, and the app reloads the timelines of the widgets that show them. The widgets
// then read through their own REST client, as they always do. A wake shows nothing, opens no socket and reads no
// sign-in itself.

enum WidgetPlacement {
    /// What each kind of widget shows, in the server's channels. The mapping is the widgets' own
    /// (`SiloWidgetKind.channels`), so the report, the wake and the live socket cannot drift apart: the Server
    /// status widget shows the stream count and the requests waiting, so it follows both.
    static func channels(forKind kind: SiloWidgetKind) -> Set<WidgetChannel> {
        Set(kind.channels.compactMap(WidgetChannel.init(rawValue:)))
    }

    /// The report for the widget kinds that are placed (WidgetKit's `kind` strings). A kind this build does not
    /// know is not ours and counts for nothing.
    static func report(placedKinds: Set<String>) -> WidgetReport {
        let channels = placedKinds.compactMap(SiloWidgetKind.init(rawValue:)).reduce(into: Set<WidgetChannel>()) {
            $0.formUnion(channels(forKind: $1))
        }
        return WidgetReport(placed: !channels.isEmpty, channels: channels)
    }

    /// The widgets a wake for `channels` reloads: every kind that shows one of them, in a fixed order.
    static func kinds(reloadedBy channels: Set<WidgetChannel>) -> [SiloWidgetKind] {
        let reloaded = WidgetReload.kinds(forChannels: channels.map(\.rawValue))
        return SiloWidgetKind.allCases.filter(reloaded.contains)
    }
}

/// Which widgets the person has placed (Home Screen, Lock Screen, StandBy).
protocol WidgetPlacementReading: Sendable {
    /// The `kind` of every placed widget, or nil when WidgetKit could not say (the report is then left alone).
    func placedKinds() async -> Set<String>?
}

struct SystemWidgetPlacements: WidgetPlacementReading {
    func placedKinds() async -> Set<String>? {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                switch result {
                case .success(let widgets): continuation.resume(returning: Set(widgets.map(\.kind)))
                case .failure: continuation.resume(returning: nil)
                }
            }
        }
    }
}

extension WidgetPlacementReading {
    /// The report the registrar sends; nil when the placements could not be read.
    func report() async -> WidgetReport? {
        await placedKinds().map(WidgetPlacement.report(placedKinds:))
    }
}

protocol WidgetKindReloading: Sendable {
    func reload(kinds: [SiloWidgetKind])
}

/// The app's one reload path (`WidgetReload`).
struct SystemWidgetKindReloader: WidgetKindReloading {
    func reload(kinds: [SiloWidgetKind]) {
        WidgetReload.reload(Set(kinds))
    }
}

/// What the app does when a push reaches it in the background (`remote-notification`).
///
/// - A **widget wake** (`widgets-{channels}-{time}` after the device id) names the channels that changed; the
///   widgets that show them reload.
/// - An **alert push** woke the app because something happened that a widget may show, and its kind is in the
///   server's content, not the push, so every widget reloads. The server relies on this when it skips a wake
///   right after an alert.
///
/// Reloading widget timelines is all either does. Neither posts a notification, opens a socket or reads a
/// sign-in, and a push for a device this phone has no live registration for (signed out, being retired, not
/// ours) is ignored.
struct PushBackgroundHandler: Sendable {
    enum Outcome: Equatable, Sendable {
        /// These widgets were reloaded.
        case reloaded([SiloWidgetKind])
        /// Not an admin push at all.
        case notOurs
        /// A push for a device this phone has no live registration for.
        case unknownDevice
        /// A wake naming no channel this build has.
        case nothingToReload
    }

    let registrations: any PushRegistrationStoring
    let reloader: any WidgetKindReloading

    @discardableResult
    func handle(_ wire: PushWire?) -> Outcome {
        guard let wire else { return .notOurs }
        guard registrations.registration(deviceID: wire.deviceID) != nil else { return .unknownDevice }
        let kinds: [SiloWidgetKind]
        if let wake = WidgetWake(wire: wire) {
            kinds = WidgetPlacement.kinds(reloadedBy: wake.channels)
        } else {
            kinds = SiloWidgetKind.allCases
        }
        guard !kinds.isEmpty else { return .nothingToReload }
        reloader.reload(kinds: kinds)
        return .reloaded(kinds)
    }
}
