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

    /// Hide tickets whose dispatch is in flight or done (failed ones return).
    private var items: [InboxItem] {
        store.items.filter { !sessions.hiddenIssueIDs.contains($0.id) }
    }
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

                    if case .loading = store.phase, items.isEmpty {
                        statePanel(
                            title: "Loading inbox",
                            message: "Fetching assigned GitHub issues from your Mac.",
                            systemImage: "arrow.clockwise"
                        )
                        .padding(.horizontal, LoupeSpace.screenInset)
                    } else if case .loaded = store.phase, items.isEmpty {
                        statePanel(
                            title: "Inbox is clear",
                            message: "Assigned GitHub issues will appear here when they are ready to dispatch.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .padding(.horizontal, LoupeSpace.screenInset)
                    }

                    ForEach(items) { item in
                        TicketCard(
                            item: item,
                            onDispatch: { dispatch(item, harness: $0) },
                            onRefreshBlueprint: { store.refreshBlueprint(item) }
                        )
                        .transition(.flyToPill)
                    }
                }
                .padding(.bottom, LoupeSpace.xxl)
            }
            .refreshable {
                let haptic = UIImpactFeedbackGenerator(style: .light)
                haptic.prepare()
                haptic.impactOccurred()
                await store.refresh()
            }
            .loupeStickyTopBar { stickyHeader }
        }
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
            Text("You're viewing sample tickets. Pair a Mac to dispatch to a real agent.")
        }
        .sheet(isPresented: $showWorkstationPicker) {
            workstationSheet
        }
        .sheet(isPresented: $showSessions) {
            if let pairing = store.pairing {
                SessionsListView(sessions: sessions, pairing: pairing)
            }
        }
        .onDisappear { pendingDispatchTask?.cancel() }
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
        let running = sessions.runningCount
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

                if running > 0 {
                    Text("\(running)")
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
                if running > 0 {
                    Capsule().stroke(Color.accent, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: running)
        .accessibilityLabel(running > 0 ? "\(running) running session\(running == 1 ? "" : "s"), tap to view" : "Sessions")
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
            if let lastSynced = store.lastSynced {
                Text(syncLabel(for: lastSynced))
                    .font(LoupeFont.caption)
                    .foregroundStyle(Color.textSecondary)
                    .alignmentGuide(.inboxBadge) { dimensions in
                        dimensions[.firstTextBaseline] - 4
                    }
            }
        }
        .padding(.vertical, 18)
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
    HomeView(store: InboxStore(), sessions: SessionsStore())
}
