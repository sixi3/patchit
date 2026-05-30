import SwiftUI

// MARK: - AgentGlyph
// Placeholder for the colored agent icons (codex/claude) you'll drop in later.
// Renders a tinted rounded badge with the agent initial until real assets exist.
struct AgentGlyph: View {
    let agent: Agent
    var size: CGFloat = 22

    private var tint: Color {
        switch agent {
        case .codex:  return Color(hex: 0xE5533A)   // codex orange
        case .claude: return Color(hex: 0x6B5BFF)   // claude indigo
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(
                Text(agent == .codex ? "{ }" : "✦")
                    .font(.system(size: size * 0.42, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            )
            .accessibilityLabel(agent.label)
    }
}

// MARK: - PriorityGlyphs
// The dual top-left glyphs: issue type + priority caret. (Colored set comes later.)
struct PriorityGlyphs: View {
    let type: IssueType
    let priority: LoupePriority

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: type.sfSymbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(priority.rail)
            Image(systemName: priority.caretSymbol)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(priority.rail)
        }
    }
}

// MARK: - RepoPill
struct RepoPill: View {
    let repo: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")        // → Ph.gitBranch
                .font(.system(size: 11, weight: .bold))
            Text(repo).font(LoupeFont.code)
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.chipFill))
    }
}

// MARK: - MetricStat
// Folder/siren counts under the summary.
struct MetricStat: View {
    let symbol: String
    let tint: Color
    let value: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(value)")
                .font(LoupeFont.metric)
                .foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.chipFill))
    }
}

struct CostStat: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accent)
            Text(value)
                .font(LoupeFont.metric)
                .foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.chipFill))
    }
}

// MARK: - FileChip
struct FileChip: View {
    let path: String
    private var kind: FileKind { FileKind.from(path) }
    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.sfSymbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(kind.tint)
            Text(name)
                .font(LoupeFont.code)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        }
    }
}

// MARK: - FlowingFiles
// Wraps file chips with a leading dot separator like the screenshot.
struct FilesRow: View {
    let files: [BlueprintFile]
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(files.enumerated()), id: \.element.id) { idx, file in
                HStack(spacing: 8) {
                    if idx > 0 {
                        Circle().fill(Color.textMuted.opacity(0.5)).frame(width: 3, height: 3)
                    }
                    FileChip(path: file.path)
                }
            }
        }
    }
}

// MARK: - InboxCountBadge
struct InboxCountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accent))
    }
}

// MARK: - FlowLayout (carried over — wraps chips correctly)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews: subviews, proposalWidth: proposal.width ?? 0).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews: subviews, proposalWidth: bounds.width)
        for item in arrangement.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func arrange(subviews: Subviews, proposalWidth: CGFloat) -> (items: [(index: Int, origin: CGPoint, size: CGSize)], size: CGSize) {
        var items: [(Int, CGPoint, CGSize)] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        let maxWidth = max(proposalWidth, 1)

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            items.append((index, CGPoint(x: x, y: y), size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (items, CGSize(width: maxWidth, height: y + rowHeight))
    }
}
