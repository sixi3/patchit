import SwiftUI

// MARK: - RootView
// Gates on pairing: unpaired → PairingView, paired → HomeView.
// A shared InboxStore is the single source of truth across both.
struct RootView: View {
    @State private var store = InboxStore()
    @State private var sessions = SessionsStore()

    var body: some View {
        Group {
            if store.isPaired {
                if store.githubConnected {
                    HomeView(store: store, sessions: sessions)
                } else {
                    ConnectGitHubView(store: store)
                }
            } else {
                PairingView(store: store)
            }
        }
        .animation(.snappy, value: store.isPaired)
        .animation(.snappy, value: store.githubConnected)
    }
}
