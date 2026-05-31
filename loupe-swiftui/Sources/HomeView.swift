import SwiftUI

// MARK: - HomeView (inbox)
// Rebuilt on the Loupe design system to match Figma node 210:18465.
struct HomeView: View {
    @State var store: InboxStore
    @State private var dispatchItem: InboxItem?
    @State private var notPairedAlert = false
    @State private var showWorkstationPicker = false
    @State private var showAgentsSheet = false

    private var items: [InboxItem] { store.items }
    private var workstation: String { store.workstation }
    private var onlineAgents: [Agent] { store.onlineAgents }

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: LoupeSpace.cardGap) {
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
            .refreshable { await store.refresh() }
            .loupeStickyTopBar { stickyHeader }
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
        .sheet(isPresented: $showWorkstationPicker) {
            workstationSheet
        }
        .sheet(isPresented: $showAgentsSheet) {
            agentsSheet
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.riskAlert)
                Text(message)
                    .font(LoupeFont.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Retry") { Task { await store.refresh() } }
                    .font(LoupeFont.caption)
                    .foregroundStyle(Color.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Color.chipFill))
                Button("Re-pair Mac") { store.unpair() }
                    .font(LoupeFont.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Color.accent))
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: LoupeRadius.control).stroke(Color.hairline, lineWidth: 1))
    }

    // MARK: Sticky header (user row + inbox title)
    private var stickyHeader: some View {
        VStack(spacing: 0) {
            userInfoRow
                .padding(.horizontal, LoupeSpace.screenInset)
            inboxHeader
                .padding(.horizontal, LoupeSpace.screenInset)
        }
    }

    // MARK: User info / workstation selector
    private var userInfoRow: some View {
        HStack(spacing: LoupeSpace.md) {
            profileButton

            Button { showWorkstationPicker = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workstation:")
                        .font(LoupeFont.label)
                        .foregroundStyle(Color.textMuted)
                    HStack(spacing: 8) {
                        Circle().fill(Color.onlineDot).frame(width: LoupeSize.statusDot, height: LoupeSize.statusDot)
                        Text(workstation)
                            .font(LoupeFont.workstation)
                            .foregroundStyle(Color.textPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.textMuted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            agentPillButton
        }
        .padding(.top, 6)
        .modifier(GlassHeaderContainerModifier())
    }

    private var profileButton: some View {
        Button { showWorkstationPicker = true } label: {
            Text("A")
                .font(LoupeFont.headline)
                .foregroundStyle(Color.textPrimary)
                .frame(width: LoupeSize.avatar, height: LoupeSize.avatar)
                .contentShape(Circle())
                .loupeGlassCircle(interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile and workstation")
    }

    private var agentPillButton: some View {
        Button { showAgentsSheet = true } label: {
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
            .contentShape(Capsule())
            .loupeGlassCapsule(interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(onlineAgents.count) online agents")
    }

    // MARK: Inbox title
    private var inboxHeader: some View {
        HStack(alignment: .inboxBadge, spacing: 10) {
            Text("Inbox")
                .font(LoupeFont.largeTitle)
                .foregroundStyle(Color.textPrimary)
                .alignmentGuide(.inboxBadge) { dimensions in
                    dimensions[.firstTextBaseline] - 10
                }
            InboxCountBadge(count: items.count)
                .alignmentGuide(.inboxBadge) { dimensions in
                    dimensions[VerticalAlignment.center]
                }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
    }

    // MARK: Sheets
    private var workstationSheet: some View {
        NavigationStack {
            List {
                Section("Connected") {
                    HStack(spacing: 10) {
                        Circle().fill(Color.onlineDot).frame(width: LoupeSize.statusDot, height: LoupeSize.statusDot)
                        Text(workstation)
                            .font(LoupeFont.workstation)
                    }
                }
            }
            .navigationTitle("Workstation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showWorkstationPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var agentsSheet: some View {
        NavigationStack {
            List {
                ForEach(onlineAgents, id: \.self) { agent in
                    HStack(spacing: 12) {
                        AgentGlyph(agent: agent, size: 28)
                        Text(agent.label)
                            .font(LoupeFont.headline)
                    }
                }
            }
            .navigationTitle("Online agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showAgentsSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// Wraps the header glass controls in GlassEffectContainer on iOS 26+ for proper touch refraction.
private struct GlassHeaderContainerModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

// Aligns a small badge to the visual center of the 30pt Inbox title (custom fonts sit high in their line box).
private extension VerticalAlignment {
    enum InboxBadgeAlignment: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    static let inboxBadge = VerticalAlignment(InboxBadgeAlignment.self)
}

#Preview {
    HomeView(store: InboxStore())
}
