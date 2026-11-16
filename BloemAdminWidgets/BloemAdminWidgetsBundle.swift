import SwiftUI
import WidgetKit

@main
struct BloemAdminWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ServerStatusWidget()
        NowPlayingWidget()
        RequestsWidget()
        LibrariesWidget()
        NodesWidget()
        AdminJobLiveActivity()
        if #available(iOS 18.0, *) {
            NowPlayingControl()
            RequestsWaitingControl()
        }
    }
}
