import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity for a library scan or a backup started from the app, on the Lock Screen and in the
/// Dynamic Island. A tap opens Libraries or Backups on that server.
struct AdminJobLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AdminJobActivityAttributes.self) { context in
            AdminJobLockScreenHost(attributes: context.attributes, state: context.state)
                .widgetURL(context.attributes.link)
        } dynamicIsland: { context in
            let palette = WidgetPalette.dark
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetIconView(icon: context.attributes.kind == .backup ? .archive : .library, size: 18)
                        .foregroundStyle(palette.muted)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(verbatim: context.state.title(kind: context.attributes.kind))
                        .bloemText(.titleSmall).foregroundStyle(palette.text)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let percent = context.state.percentText {
                        Text(verbatim: percent).bloemText(.titleSmall).foregroundStyle(palette.accent)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AdminJobDetailView(attributes: context.attributes, state: context.state, palette: palette)
                }
            } compactLeading: {
                WidgetIconView(icon: context.attributes.kind == .backup ? .archive : .library, size: 14)
                    .foregroundStyle(palette.text)
            } compactTrailing: {
                Text(verbatim: context.state.percentText ?? "…").bloemText(.labelMedium).foregroundStyle(palette.accent)
            } minimal: {
                WidgetIconView(icon: context.attributes.kind == .backup ? .archive : .library, size: 14)
                    .foregroundStyle(palette.text)
            }
            .widgetURL(context.attributes.link)
        }
    }
}

/// The Lock Screen presentation in the system's scheme.
struct AdminJobLockScreenHost: View {
    let attributes: AdminJobActivityAttributes
    let state: AdminJobActivityAttributes.ContentState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        AdminJobLockScreenView(attributes: attributes, state: state, palette: .of(scheme))
    }
}
