import SwiftUI

// MARK: - RootView
// Gates on pairing: unpaired → PairingView, paired → HomeView.
// A shared InboxStore is the single source of truth across both.
struct RootView: View {
    @State private var store = InboxStore()
    @State private var sessions = SessionsStore()

    var body: some View {
        Group {
            #if DEBUG
            if CommandLine.arguments.contains("-LoupePreviewHandoff") {
                NavigationStack {
                    SessionView(store: .previewHandoff, pairing: .preview)
                }
            } else if CommandLine.arguments.contains("-LoupePreviewHome") {
                HomeView(store: store, sessions: sessions)
            } else {
                gatedContent
            }
            #else
            gatedContent
            #endif
        }
        .animation(.snappy, value: store.isPaired)
        .animation(.snappy, value: store.githubConnected)
        .task(id: store.pairing?.host) {
            if let pairing = store.pairing {
                await sessions.hydrate(pairing: pairing)
            }
        }
    }

    @ViewBuilder
    private var gatedContent: some View {
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
}
