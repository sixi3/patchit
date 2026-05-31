import SwiftUI

// MARK: - Ticket detail tabs
enum TicketDetailTab: Hashable {
    case files
    case risks
}

// MARK: - TicketCard
// The inbox card from node 210:18465: priority rail + hatched header, title,
// repo pill, confidence ring + summary, metric tabs, detail panel, dispatch row.
struct TicketCard: View {
    let item: InboxItem
    var onDispatch: () -> Void = {}
    var onMore: () -> Void = {}

    @State private var selectedTab: TicketDetailTab = .files
    @State private var isSummaryExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            body_
        }
        .background(Color.surface)
        .onAppear { reconcileSelectedTab() }
        .onChange(of: item.id) { _, _ in
            reconcileSelectedTab()
            isSummaryExpanded = false
        }
    }

    private var availableTabs: [TicketDetailTab] {
        var tabs: [TicketDetailTab] = []
        if !item.blueprint.files.isEmpty { tabs.append(.files) }
        if !item.blueprint.riskAreas.isEmpty { tabs.append(.risks) }
        return tabs
    }

    private func reconcileSelectedTab() {
        let tabs = availableTabs
        guard let first = tabs.first else { return }
        if !tabs.contains(selectedTab) {
            selectedTab = first
        }
    }

    private func selectTab(_ tab: TicketDetailTab) {
        guard availableTabs.contains(tab) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedTab = tab
        }
    }

    // Hatched, priority-tinted top zone — rail is header-height only.
    private var header: some View {
        HStack(spacing: 0) {
            item.priority.rail
                .frame(width: LoupeSize.rail)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: LoupeRadius.railCorner,
                        topTrailingRadius: LoupeRadius.railCorner
                    )
                )

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    PriorityGlyphs(type: item.issueType, priority: item.priority)
                    Text(item.reference)
                        .font(LoupeFont.code)
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    Text(item.updatedAt)
                        .font(LoupeFont.code)
                        .foregroundStyle(Color.textMuted)
                }

                Text(item.title)
                    .font(LoupeFont.title)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, LoupeSpace.lg)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PriorityHeaderBackground(priority: item.priority))
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 6) {
                Text("In").font(LoupeFont.body).foregroundStyle(Color.textMuted)
                RepoPill(repo: item.repo)
                Spacer(minLength: 8)
                if let cost = item.costStripLabel {
                    Text(cost)
                        .font(LoupeFont.costStrip)
                        .monospacedDigit()
                        .foregroundStyle(Color.textMuted)
                }
            }

            if item.isDegraded { degradedNotice }

            HStack(alignment: .center, spacing: 12) {
                ConfidenceRing(value: item.isAnalyzing ? 0 : item.confidence)
                    .opacity(item.isDegraded ? 0.4 : 1)
                ExpandableSummaryText(text: summaryText, isExpanded: $isSummaryExpanded)
            }
            .animation(.easeInOut(duration: 0.2), value: isSummaryExpanded)

            if !availableTabs.isEmpty {
                detailTabStrip
                detailPanel
            }

            dispatchRow
        }
        .padding(LoupeSpace.lg)
    }

    @ViewBuilder
    private var detailTabStrip: some View {
        HStack(spacing: 10) {
            if !item.blueprint.files.isEmpty {
                MetricTab(
                    symbol: "folder.fill",
                    tint: Color(hex: 0xE0A33E),
                    value: item.fileCount,
                    isSelected: selectedTab == .files,
                    action: { selectTab(.files) }
                )
                .accessibilityLabel("Files, \(item.fileCount)")
            }
            if !item.blueprint.riskAreas.isEmpty {
                MetricTab(
                    symbol: "light.beacon.max.fill",
                    tint: .riskAlert,
                    value: item.riskCount,
                    isSelected: selectedTab == .risks,
                    action: { selectTab(.risks) }
                )
                .accessibilityLabel("Risks, \(item.riskCount)")
            }
        }
    }

    /// Both panels stay in the layout so card height does not change when switching tabs.
    private var detailPanel: some View {
        ZStack(alignment: .topLeading) {
            if !item.blueprint.files.isEmpty {
                FilesRow(files: item.blueprint.files)
                    .opacity(selectedTab == .files ? 1 : 0)
                    .allowsHitTesting(selectedTab == .files)
                    .accessibilityHidden(selectedTab != .files)
            }
            if !item.blueprint.riskAreas.isEmpty {
                RisksRow(areas: item.blueprint.riskAreas)
                    .opacity(selectedTab == .risks ? 1 : 0)
                    .allowsHitTesting(selectedTab == .risks)
                    .accessibilityHidden(selectedTab != .risks)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
    }

    private var dispatchRow: some View {
        HStack(spacing: 10) {
            Button(action: onDispatch) {
                HStack(spacing: 8) {
                    Text(dispatchTitle)
                        .font(LoupeFont.button)
                        .foregroundStyle(item.isReady ? Color.textPrimary : Color.textMuted)
                    if item.isReady { AgentGlyph(agent: item.targetAgent, size: 22) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: LoupeRadius.control)
                        .fill(Color.chipFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: LoupeRadius.control)
                                .stroke(Color.hairline, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!item.isReady)

            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: LoupeSize.kebab, height: LoupeSize.kebab)
                    .background(
                        RoundedRectangle(cornerRadius: LoupeRadius.control)
                            .fill(Color.chipFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: LoupeRadius.control)
                                    .stroke(Color.hairline, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var degradedNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: 0xE8912A))
            Text("Couldn't analyze the code — estimate from ticket text only.")
                .font(LoupeFont.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color(hex: 0xE8912A, alpha: 0.10)))
    }

    private var summaryText: String {
        if item.isAnalyzing { return item.blueprint.summary ?? "Analyzing ticket..." }
        return item.blueprint.summary ?? ""
    }

    private var dispatchTitle: String {
        if item.isAnalyzing { return "Analyzing" }
        return item.isReady ? "Dispatch" : "Needs info"
    }
}
