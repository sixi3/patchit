import SwiftUI

// MARK: - HandoffSummary
// One derived read of the finished session: the condensed "receipt" that powers
// both the sticky bento dock and its drawers. The chat is the story; this is the
// structured output the agent emits as a HANDOFF block (see daemon withHandoffContract).
struct HandoffSummary {
    let handoff: SessionEvent.Handoff?
    let files: [SessionFileChange]
    let branchName: String?
    let baseBranch: String?
    let repo: String?
    let prRef: SessionStore.PRRef?
    let committed: Bool

    @MainActor
    init(store: SessionStore) {
        let events = store.events
        let capturedHandoff = events.last(where: { $0.type == "handoff" })?.handoff
        handoff = capturedHandoff
        let changedFiles = SessionFileChange.coalesced(from: events)
        if changedFiles.isEmpty {
            files = (capturedHandoff?.filesChanged ?? []).map {
                SessionFileChange(path: $0, status: "modified", additions: 0, deletions: 0, patch: nil)
            }
        } else {
            files = changedFiles
        }
        let branchEvent = events.last { $0.type == "branch" && ($0.kind == "created" || $0.kind == "committed") }
        branchName = store.branch?.name ?? branchEvent?.branch
        baseBranch = store.branch?.base
        repo = store.branch?.repo ?? store.prRef.map { "\($0.owner)/\($0.repo)" }
        prRef = store.prRef
        committed = events.contains { $0.type == "branch" && $0.kind == "committed" }
    }

    // MARK: Facet data
    var tldr: String? {
        let value = handoff?.tldr?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }
    var whatChanged: [String] { handoff?.whatChanged ?? [] }
    var checksPassed: [String] { handoff?.testsRun ?? [] }
    var checksSkipped: [String] { handoff?.testsNotRun ?? [] }
    var risks: [String] { (handoff?.risks ?? []) + (handoff?.assumptions ?? []) }

    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    var confidence: Int? {
        guard let raw = handoff?.confidence else { return nil }
        let normalized = raw > 1 ? raw : raw * 100
        return min(100, max(0, Int(normalized.rounded())))
    }

    /// True only when there's a real handoff worth docking.
    var isPresent: Bool {
        tldr != nil || !files.isEmpty || !whatChanged.isEmpty || prRef != nil
    }

    // MARK: Pills (only the facets that carry data)
    var pills: [HandoffPill] {
        var result: [HandoffPill] = []
        if tldr != nil || !whatChanged.isEmpty {
            result.append(.init(facet: .summary, icon: "text.alignleft", tint: .accent,
                                title: "Summary",
                                metric: whatChanged.isEmpty ? "Overview" : "\(whatChanged.count) notes"))
        }
        if !files.isEmpty {
            result.append(.init(facet: .files, icon: "folder.fill", tint: Color(hex: 0xE0A33E),
                                title: files.count == 1 ? "1 file" : "\(files.count) files",
                                metric: diffMetric))
        }
        if !checksPassed.isEmpty || !checksSkipped.isEmpty {
            result.append(.init(facet: .checks, icon: "checkmark.circle.fill", tint: .ringHigh,
                                title: "Checks",
                                metric: checksMetric))
        }
        if !risks.isEmpty {
            result.append(.init(facet: .watch, icon: "light.beacon.max.fill", tint: .riskAlert,
                                title: "Watch",
                                metric: "\(risks.count)"))
        }
        if let branchName {
            result.append(.init(facet: .branch, icon: "arrow.triangle.branch", tint: .accent,
                                title: "Branch",
                                metric: branchName.shortBranch))
        }
        if prRef != nil || committed {
            result.append(.init(facet: .commit, icon: "arrow.triangle.pull", tint: .accent,
                                title: prRef != nil ? "PR" : "Commit",
                                metric: prRef.map { "#\($0.number)" } ?? "Ready"))
        }
        return result
    }

    private var diffMetric: String {
        if additions > 0 || deletions > 0 { return "+\(additions) −\(deletions)" }
        return files.count == 1 ? "1 change" : "\(files.count) changes"
    }
    private var checksMetric: String {
        if !checksPassed.isEmpty { return checksPassed.count == 1 ? "1 passed" : "\(checksPassed.count) passed" }
        return checksSkipped.count == 1 ? "1 skipped" : "\(checksSkipped.count) skipped"
    }
}

enum HandoffFacet: String, Identifiable, Hashable {
    case summary, files, checks, watch, branch, commit
    var id: String { rawValue }
}

struct HandoffPill: Identifiable {
    let facet: HandoffFacet
    let icon: String
    let tint: Color
    let title: String
    let metric: String
    var id: HandoffFacet { facet }
}

// MARK: - HandoffDock
// Sticky floating bento cluster pinned to the bottom of the session. Each pill
// opens a detail drawer; the primary CTA carries the review/share handoff.
struct HandoffDock: View {
    let summary: HandoffSummary
    let canReview: Bool
    @Binding var openFacet: HandoffFacet?
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            FlowLayout(spacing: 8) {
                ForEach(summary.pills) { pill in
                    BentoPill(pill: pill) { openFacet = pill.facet }
                }
            }

            Button(action: onReview) {
                HStack(spacing: 7) {
                    Image(systemName: "checklist")
                        .font(.system(size: 14, weight: .bold))
                    Text(canReview ? "Review changes" : "No PR to review")
                        .font(LoupeFont.button)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: LoupeRadius.control)
                    .fill(canReview ? Color.accent : Color.textMuted.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .disabled(!canReview)
        }
        .padding(16)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(Color.surface)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .stroke(Color.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, y: -6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.ringHigh)
            Text("Handoff")
                .font(LoupeFont.headline)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if let confidence = summary.confidence {
                HStack(spacing: 5) {
                    Circle().fill(confidenceTint(confidence)).frame(width: 7, height: 7)
                    Text("\(confidence)% confidence")
                        .font(LoupeFont.code)
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
    }

    private func confidenceTint(_ value: Int) -> Color {
        if value >= 80 { return .ringHigh }
        if value >= 65 { return .ringMid }
        return .ringLow
    }
}

private struct BentoPill: View {
    let pill: HandoffPill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pill.icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(pill.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pill.title)
                        .font(LoupeFont.caption)
                        .foregroundStyle(Color.textMuted)
                    Text(pill.metric)
                        .font(LoupeFont.codeStrong)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.chipFill))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FlowLayout
// Wrapping row layout so pills size to content and bento-wrap to fill the dock.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: maxWidth == .infinity ? rows.map(\.width).max() ?? 0 : maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = rows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

private extension String {
    /// Drop a long `loupe/feature/x` prefix to its last segment for a compact pill.
    var shortBranch: String {
        let parts = split(separator: "/")
        return parts.count > 1 ? parts.suffix(2).joined(separator: "/") : self
    }
}
