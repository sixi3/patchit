import SwiftUI

// MARK: - RootView
// Gates on pairing: unpaired → PairingView, paired → HomeView.
// A shared InboxStore is the single source of truth across both.
struct RootView: View {
    @State private var store = InboxStore()

    var body: some View {
        Group {
            if store.isPaired {
                HomeView(store: store)
            } else {
                PairingView(store: store)
            }
        }
        .animation(.snappy, value: store.isPaired)
    }
}
