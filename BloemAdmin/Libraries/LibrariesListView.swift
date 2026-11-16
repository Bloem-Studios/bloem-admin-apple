import SwiftUI

/// Libraries of one server: each library with Scan, Stop, Check the mount and Refresh metadata, what its scans and
/// refreshes are doing, and the recent scans. The page reads the server when it opens and when the app returns,
/// and again whenever the shared events socket says the `scans` or `jobs` channel changed (a scan queued, moved,
/// finished; a metadata refresh moved). Scan progress is read over REST: the socket only says that something
/// changed. If the socket is down for good the page is read at most once a minute, and not at all otherwise.
struct LibrariesListView: View {
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @Environment(ShellRouter.self) private var router: ShellRouter?
    @State private var viewModel: LibrariesViewModel

    init(client: APIClient) {
        self.client = client
        _viewModel = State(initialValue: LibrariesViewModel())
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LibrariesSectionView(viewModel: viewModel, client: client, sessionState: sessionState)
                    .padding()
            }
            .overlay {
                if let failure = viewModel.loadFailure, viewModel.libraries.isEmpty {
                    LoadFailureView(failure: failure) { Task { await viewModel.load(client: client, sessionState: sessionState) } }
                        .background(.background)
                } else if !viewModel.hasLoaded {
                    ProgressView()
                }
            }
            .refreshable { await viewModel.load(client: client, sessionState: sessionState) }
            .liveRefresh(client: client, channels: LibrariesLive.channels) {
                await viewModel.load(client: client, sessionState: sessionState)
            }
            // A link that names a library (a tapped notification) scrolls to it once the page has it.
            .onChange(of: router?.itemFocus, initial: true) { _, _ in scrollToFocusedLibrary(proxy) }
            .onChange(of: viewModel.libraries.map(\.id)) { _, _ in scrollToFocusedLibrary(proxy) }
            .onChange(of: viewModel.hasLoaded) { _, _ in scrollToFocusedLibrary(proxy) }
            .accessibilityIdentifier("libraries-page")
        }
    }

    /// Scrolls to the library a link named. A library the page does not have after it has loaded is dropped.
    private func scrollToFocusedLibrary(_ proxy: ScrollViewProxy) {
        guard let router, let focus = router.itemFocus, focus.pageID == DeepLinkPage.libraries else { return }
        if viewModel.libraries.contains(where: { $0.id == focus.itemID }) {
            _ = router.takeItemFocus(for: DeepLinkPage.libraries)
            withAnimation { proxy.scrollTo(focus.itemID, anchor: .top) }
        } else if viewModel.hasLoaded {
            _ = router.takeItemFocus(for: DeepLinkPage.libraries)
        }
    }
}

/// What moves the Libraries page: scans (queued, progress, finished) and jobs (metadata refreshes).
enum LibrariesLive {
    static let channels: Set<LiveChannel> = [.scans, .jobs]
}
