import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center control "Now playing" (iOS 18 and later). It opens the app on Now playing across
/// all servers, through the app lock and the admin gate; it shows nothing about any server. It can also
/// be put on the Lock Screen or the Action button.
@available(iOS 18.0, *)
struct NowPlayingControl: ControlWidget {
    static let kind = "com.bloemstudios.admin.control.now-playing"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenNowPlayingIntent()) {
                Label("Now playing", image: "lucide.radio")
            }
        }
        .displayName("Bloem Admin: Now playing")
        .description("Bloem Admin: opens the app on Now playing")
    }
}
