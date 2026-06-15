import SwiftUI

// MARK: - HomeView (inbox)
// Rebuilt on the Loupe design system to match Figma node 210:18465.
struct HomeView: View {
    @State var store: InboxStore
    let sessions: SessionsStore
    @State private var pendingDispatch: PendingDispatch?
    @State private var pendingDispatchTask: Task<Void, Never>?
    @State private var notPairedAlert = false
    @State private var showWorkstationPicker = false
    @State private var showSessions = false
    @State private var homeTab: HomeTab = .tickets
    @State private var reviewPR: SessionStore.PRRef?

    /// Hide tickets whose dispatch is in flight or done (failed ones return).
    private var items: [InboxItem] {
        store.items.filter { !sessions.hiddenIssueIDs.contains($0.id) }
    }
    private var workstation: String { store.workstation }
    private var onlineAgents: [Agent] { store.onlineAgents }

    var body: some View {
        homeContent
        .task {
            if store.isPaired { await store.refresh() }
        }
        .safeAreaInset(edge: .bottom) {
            if let pendingDispatch {
                PendingDispatchBanner(
                    pending: pendingDispatch,
                    onCancel: cancelPendingDispatch,
                    onDispatchNow: { commitPendingDispatch(pendingDispatch.id) }
                )
                .padding(.horizontal, LoupeSpace.screenInset)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: pendingDispatch?.id)
        .alert("Pair your Mac first", isPresented: $notPairedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Pair a Mac to fetch tickets and dispatch to a real agent.")
        }
        .sheet(isPresented: $showWorkstationPicker) {
            workstationSheet
        }
        .sheet(isPresented: $showSessions) {
            if let pairing = store.pairing {
                SessionsListView(sessions: sessions, pairing: pairing)
            }
        }
        .fullScreenCover(item: $reviewPR) { ref in
            if let pairing = store.pairing {
                PRReviewView(store: PRReviewStore(ref: ref, pairing: pairing))
            }
        }
        .onDisappear { pendingDispatchTask?.cancel() }
    }

    // MARK: Home shell (native bottom tabs on iOS 26, top tabs as fallback)
    @ViewBuilder
    private var homeContent: some View {
        if #available(iOS 26.0, *) {
            nativeTabHome
        } else {
            legacyTabHome
        }
    }

    /// iOS 26: native Liquid Glass tab bar pinned to the bottom. It minimizes
    /// (slides toward the bottom) on scroll-down and restores on scroll-up via
    /// `tabBarMinimizeBehavior`. A horizontal swipe still pages between tabs.
    @available(iOS 26.0, *)
    private var nativeTabHome: some View {
        TabView(selection: $homeTab) {
            Tab(HomeTab.tickets.title, systemImage: HomeTab.tickets.icon, value: HomeTab.tickets) {
                homeTabPage { ticketsContent }
                    .loupeStickyTopBar { topHeaderRow }
            }
            Tab(HomeTab.prs.title, systemImage: HomeTab.prs.icon, value: HomeTab.prs) {
                homeTabPage { prsContent }
                    .loupeStickyTopBar { topHeaderRow }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Color.accent)
        .background(Color.canvas.ignoresSafeArea())
        .simultaneousGesture(swipePagingGesture)
    }

    /// Pre-iOS 26 fallback: the original top glass tab switcher + horizontal pager.
    private var legacyTabHome: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            homeTabPager
                .loupeStickyTopBar { stickyHeader }
        }
    }

    /// Horizontal swipe drives the same `homeTab` selection the native bar exposes,
    /// so users keep swipe-paging between Tickets and PRs alongside the bottom bar.
    private var swipePagingGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                let tabs = HomeTab.allCases
                guard let idx = tabs.firstIndex(of: homeTab) else { return }
                let next = dx < 0 ? idx + 1 : idx - 1
                guard tabs.indices.contains(next) else { return }
                withAnimation(.snappy(duration: 0.3)) { homeTab = tabs[next] }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
    }

    private func dispatch(_ item: InboxItem, harness: Agent) {
        guard item.isReady else { return }
        if store.isPaired {
            let pending = PendingDispatch(item: item, harness: harness, duration: 4)
            pendingDispatchTask?.cancel()
            pendingDispatch = pending
            pendingDispatchTask = Task {
                try? await Task.sleep(for: .seconds(pending.duration))
                await MainActor.run {
                    commitPendingDispatch(pending.id)
                }
            }
        } else {
            notPairedAlert = true
        }
    }

    private func cancelPendingDispatch() {
        pendingDispatchTask?.cancel()
        pendingDispatchTask = nil
        pendingDispatch = nil
    }

    private func commitPendingDispatch(_ id: PendingDispatch.ID) {
        guard let pendingDispatch, pendingDispatch.id == id, let pairing = store.pairing else { return }
        pendingDispatchTask?.cancel()
        pendingDispatchTask = nil
        let item = pendingDispatch.item
        let harness = pendingDispatch.harness
        self.pendingDispatch = nil

        // Register + start the session, and let the card fly toward the pill
        // (it leaves the inbox because its id enters hiddenIssueIDs).
        // Register + start the session in the background; the card flies to the
        // pill. We do NOT auto-open the session — the user taps the pill to view it.
        _ = withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            sessions.dispatch(item: item, harness: harness, pairing: pairing)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private var homeTabScrollPosition: Binding<HomeTab?> {
        Binding(
            get: { homeTab },
            set: { if let tab = $0 { homeTab = tab } }
        )
    }

    private var homeTabPager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                homeTabPage { ticketsContent }
                    .containerRelativeFrame(.horizontal)
                    .id(HomeTab.tickets)
                homeTabPage { prsContent }
                    .containerRelativeFrame(.horizontal)
                    .id(HomeTab.prs)
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: homeTabScrollPosition)
    }

    @ViewBuilder
    private func homeTabPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            LazyVStack(spacing: LoupeSpace.cardGap) {
                if case .failed(let message) = store.phase {
                    connectionBanner(message)
                        .padding(.horizontal, LoupeSpace.screenInset)
                }
                content()
            }
            .padding(.bottom, LoupeSpace.xxl)
            .frame(maxWidth: .infinity)
            .background(Color.canvas)
        }
        .frame(maxHeight: .infinity)
        .background(Color.canvas)
        .refreshable {
            let haptic = UIImpactFeedbackGenerator(style: .light)
            haptic.prepare()
            haptic.impactOccurred()
            await store.refresh()
            if let pairing = store.pairing {
                await sessions.hydrate(pairing: pairing, force: true)
            }
        }
    }

    @ViewBuilder
    private var ticketsContent: some View {
        if case .loading = store.phase {
            fetchingTicketsView
        } else if case .idle = store.phase, store.isPaired {
            fetchingTicketsView
        } else if case .loaded = store.phase, store.items.isEmpty {
            statePanel(title: "Inbox is clear",
                       message: "Assigned GitHub issues will appear here when they are ready to dispatch.",
                       systemImage: "checkmark.circle.fill")
                .padding(.horizontal, LoupeSpace.screenInset)
        } else if case .loaded = store.phase, items.isEmpty {
            statePanel(title: "No actionable tickets",
                       message: "Fetched tickets are already in progress or have a successful agent run.",
                       systemImage: "checkmark.circle.fill")
                .padding(.horizontal, LoupeSpace.screenInset)
        }
        LazyVStack(spacing: LoupeSpace.ticketGap) {
            ForEach(items) { item in
                TicketCard(
                    item: item,
                    isRefreshingBlueprint: store.isRefreshingBlueprint(item),
                    onDispatch: { dispatch(item, harness: $0) },
                    onRefreshBlueprint: { store.refreshBlueprint(item) }
                )
                .transition(.flyToPill)
            }
        }
    }

    private var fetchingTicketsView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.accent)
            Text("Fetching your tickets")
                .font(LoupeFont.bodyMedium)
                .foregroundStyle(Color.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 420)
        .padding(.horizontal, LoupeSpace.screenInset)
    }

    @ViewBuilder
    private var prsContent: some View {
        if case .loading = store.phase {
            fetchingTicketsView
        } else if case .idle = store.phase, store.isPaired {
            fetchingTicketsView
        } else if store.prs.isEmpty {
            statePanel(title: "No PRs to review",
                       message: "Pull requests where your review is requested will appear here.",
                       systemImage: "arrow.triangle.pull")
                .padding(.horizontal, LoupeSpace.screenInset)
        } else {
            ForEach(store.prs) { pr in
                PRRow(pr: pr) {
                    reviewPR = SessionStore.PRRef(owner: pr.owner, repo: pr.repo, number: pr.number)
                }
            }
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

    private func statePanel(title: String, message: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.accent)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(LoupeFont.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                Text(message)
                    .font(LoupeFont.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: LoupeRadius.control).stroke(Color.hairline, lineWidth: 1))
    }

    // MARK: Sticky header (legacy: user row + top tab switcher)
    private var stickyHeader: some View {
        VStack(spacing: 0) {
            userInfoRow
                .padding(.horizontal, LoupeSpace.screenInset)
            GlassTabSwitcher(selection: $homeTab)
                .padding(.horizontal, LoupeSpace.screenInset)
                .padding(.vertical, LoupeSpace.xl)
        }
    }

    // MARK: Top header (native bottom-tab mode: user row only, tabs live at the bottom)
    private var topHeaderRow: some View {
        userInfoRow
            .padding(.horizontal, LoupeSpace.screenInset)
            .padding(.vertical, LoupeSpace.sm)
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
        let running = sessions.runningCount
        let total = sessions.sessions.count
        let count = running > 0 ? running : total
        return Button { showSessions = true } label: {
            HStack(spacing: 6) {
                ZStack {
                    ForEach(Array(onlineAgents.enumerated()), id: \.offset) { idx, agent in
                        AgentGlyph(agent: agent, size: LoupeSize.agentBadge)
                            .overlay(Circle().stroke(Color.surface, lineWidth: 1.5))
                            .offset(x: CGFloat(idx) * 14)
                    }
                }
                .frame(width: LoupeSize.agentBadge + CGFloat(max(0, onlineAgents.count - 1)) * 14, alignment: .leading)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accent)
                        .contentTransition(.numericText())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: LoupeSize.avatar)
            .contentShape(Capsule())
            .loupeGlassCapsule(interactive: true)
            .overlay {
                if count > 0 {
                    Capsule().stroke(Color.accent, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: count)
        .accessibilityLabel(
            running > 0
                ? "\(running) running session\(running == 1 ? "" : "s"), tap to view"
                : "\(total) session\(total == 1 ? "" : "s"), tap to view"
        )
    }

    private func syncLabel(for date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "Updated just now" }
        if secs < 3600 { return "Updated \(secs / 60)m ago" }
        if secs < 86400 { return "Updated \(secs / 3600)h ago" }
        return "Updated \(secs / 86400)d ago"
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

}

// Card leaves the inbox shrinking toward the top-trailing pill.
extension AnyTransition {
    static var flyToPill: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .scale(scale: 0.25, anchor: .topTrailing)
                .combined(with: .offset(x: 60, y: -90))
                .combined(with: .opacity)
        )
    }
}


private struct PendingDispatch: Identifiable {
    let id = UUID()
    let item: InboxItem
    let harness: Agent
    let duration: Int
    let startedAt = Date()
}

private struct PendingDispatchBanner: View {
    let pending: PendingDispatch
    var onCancel: () -> Void
    var onDispatchNow: () -> Void

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = max(0, context.date.timeIntervalSince(pending.startedAt))
            let progress = min(1, elapsed / Double(pending.duration))
            let remaining = max(0, Int(ceil(Double(pending.duration) - elapsed)))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AgentGlyph(agent: pending.harness, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Dispatching \(pending.item.reference)")
                            .font(LoupeFont.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Text("\(pending.harness.label) starts in \(remaining)s")
                            .font(LoupeFont.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Button("Now") { onDispatchNow() }
                        .font(LoupeFont.caption)
                        .foregroundStyle(Color.accent)
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.chipFill))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel dispatch")
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.hairline)
                        Capsule()
                            .fill(Color.accent)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 4)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.surface))
            .overlay(RoundedRectangle(cornerRadius: LoupeRadius.control).stroke(Color.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 8)
        }
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

#Preview {
    HomeView(store: InboxStore(), sessions: SessionsStore())
}
