import ActivityKit
import SwiftUI
import WidgetKit

struct AdminJobLockScreenView: View {
    let attributes: AdminJobActivityAttributes
    let state: AdminJobActivityAttributes.ContentState
    var palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                WidgetIconView(icon: attributes.kind == .backup ? .archive : .library, size: 18).foregroundStyle(palette.muted)
                Text(verbatim: state.title(kind: attributes.kind)).bloemText(.titleMedium).foregroundStyle(palette.text)
                Spacer(minLength: 4)
                if let percent = state.percentText {
                    Text(verbatim: percent).bloemText(.titleMedium).foregroundStyle(palette.accent)
                }
            }
            AdminJobDetailView(attributes: attributes, state: state, palette: palette)
        }
        .padding(16)
    }
}

/// The server's name, the library's name where details are allowed, and the progress bar.
struct AdminJobDetailView: View {
    let attributes: AdminJobActivityAttributes
    let state: AdminJobActivityAttributes.ContentState
    let palette: WidgetPalette

    private var showsLibraryName: Bool {
        FileWidgetSettingsStore.appGroup()?.load().showDetailsOnLockScreen ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let name = showsLibraryName ? state.libraryName : nil
            Text(verbatim: name.map { "\($0) · \(attributes.serverName)" } ?? attributes.serverName)
                .bloemText(.bodySmall).foregroundStyle(palette.muted).lineLimit(1)
            if state.phase == .running {
                if let progress = state.progress {
                    ProgressView(value: progress).tint(palette.accent)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(palette.muted)
                }
            }
        }
    }
}
