import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center control "Requests waiting" (iOS 18 and later): the number of requests waiting for
/// approval, across all servers, from the last read; a tap opens Requests through the app lock. It shows a
/// count and nothing about a person or a title, so it is safe on the Lock Screen.
@available(iOS 18.0, *)
struct RequestsWaitingControl: ControlWidget {
    static let kind = "com.bloemstudios.admin.control.requests-waiting"

    struct Provider: ControlValueProvider {
        var previewValue: Int { 3 }

        func currentValue() async throws -> Int {
            RequestsWaitingCount.current()
        }
    }

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { count in
            ControlWidgetButton(action: OpenRequestsIntent()) {
                Label(RequestsWaitingCount.text(count), image: "lucide.inbox")
            }
        }
        .displayName("Bloem Admin: Requests waiting")
        .description("Bloem Admin: shows how many requests wait for approval and opens Requests")
    }
}
