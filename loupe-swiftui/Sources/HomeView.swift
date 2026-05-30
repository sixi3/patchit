import SwiftUI

// MARK: - HomeView (inbox)
// Rebuilt on the Loupe design system to match Figma node 210:18465.
struct HomeView: View {
    @State var store: InboxStore
    @State private var dispatchItem: InboxItem?
    @State private var notPairedAlert = false

    private var items: [InboxItem] { store.items }
    private var workstation: String { store.workstation }
    private var onlineAgents: [Agent] { store.onlineAgents }

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: LoupeSpace.cardGap) {
                    userInfoRow
                        .padding(.horizontal, LoupeSpace.screenInset)
                    inboxHeader
                        .padding(.horizontal, LoupeSpace.screenInset)

                    if case .failed(let message) = store.phase {
                        connectionBanner(message)
                            .padding(.horizontal, LoupeSpace.screenInset)
                    }

                    ForEach(items) { item in
                        TicketCard(item: item, onDispatch: { dispatch(item) })
                    }
                }
                .padding(.bottom, LoupeSpace.xxl)
            }
            .refreshable {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                await store.refresh()
            }
        }
        .task {
            if store.isPaired { await store.refresh() }
        }
        .fullScreenCover(item: $dispatchItem) { item in
            if let pairing = store.pairing {
                SessionView(store: SessionStore(item: item, pairing: pairing), pairing: pairing)
            }
        }
        .alert("Pair your Mac first", isPresented: $notPairedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You're viewing sample tickets. Pair a Mac to dispatch to a real agent.")
        }
    }

    private func dispatch(_ item: InboxItem) {
        guard item.isReady else { return }
        if store.isPaired {
            dispatchItem = item
        } else {
            notPairedAlert = true
        }
    }

    private func connectionBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.riskAlert)
            Text(message)
                .font(LoupeFont.caption)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: LoupeRadius.control).stroke(Color.hairline, lineWidth: 1))
    }

    // MARK: User info / workstation selector
    private var userInfoRow: some View {
        HStack(spacing: LoupeSpace.md) {
            // Glass avatar
            Text("A")
                .font(LoupeFont.headline)
                .foregroundStyle(Color.textPrimary)
                .frame(width: LoupeSize.avatar, height: LoupeSize.avatar)
                .loupeGlassCircle()

            VStack(alignment: .leading, spacing: 2) {
                Text("Workstation:")
                    .font(LoupeFont.label)
                    .foregroundStyle(Color.textMuted)
                HStack(spacing: 8) {
                    Circle().fill(Color.onlineDot).frame(width: LoupeSize.statusDot, height: LoupeSize.statusDot)
                    Text(workstation)
                        .font(LoupeFont.workstation)
                        .foregroundStyle(Color.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")     // → Ph.caretUpDown
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.textMuted)
                }
            }

            Spacer()

            agentPill
        }
        .padding(.top, 6)
    }

    // Glass agent-count pill
    private var agentPill: some View {
        HStack(spacing: 6) {
            ZStack {
                ForEach(Array(onlineAgents.enumerated()), id: \.offset) { idx, agent in
                    AgentGlyph(agent: agent, size: LoupeSize.agentBadge)
                        .overlay(Circle().stroke(Color.surface, lineWidth: 1.5))
                        .offset(x: CGFloat(idx) * 14)
                }
            }
            .frame(width: LoupeSize.agentBadge + CGFloat(max(0, onlineAgents.count - 1)) * 14, alignment: .leading)

            Text("\(onlineAgents.count)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, 12)
        .frame(height: LoupeSize.avatar)
        .loupeGlassCapsule()
    }

    // MARK: Inbox title
    private var inboxHeader: some View {
        HStack(spacing: 10) {
            Text("Inbox")
                .font(LoupeFont.largeTitle)
                .foregroundStyle(Color.textPrimary)
            InboxCountBadge(count: items.count)
            Spacer()
        }
        .padding(.top, 6)
    }
}

#Preview {
    HomeView(store: InboxStore())
}
