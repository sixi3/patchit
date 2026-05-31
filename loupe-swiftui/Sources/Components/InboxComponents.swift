import SwiftUI

// MARK: - AgentGlyph
// Uses the colored asset icons (AgentCodex / AgentClaude) when present in the
// asset catalog; falls back to a tinted badge until those PNGs are added.
struct AgentGlyph: View {
    let agent: Agent
    var size: CGFloat = 22

    private var assetName: String { agent == .codex ? "AgentCodex" : "AgentClaude" }
    private var tint: Color {
        switch agent {
        case .codex:  return Color(hex: 0xE5533A)   // codex orange
        case .claude: return Color(hex: 0x6B5BFF)   // claude indigo
        }
    }

    var body: some View {
        Group {
            if UIImage(named: assetName) != nil {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(tint)
                    .frame(width: size, height: size)
                    .overlay(
                        Text(agent == .codex ? "{ }" : "✦")
                            .font(.system(size: size * 0.42, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    )
            }
        }
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

    private enum Metrics {
        static let height: CGFloat = 20
        static let iconBox: CGFloat = 11
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "arrow.triangle.branch")        // → Ph.gitBranch
                .font(.system(size: 9, weight: .bold))
                .frame(width: Metrics.iconBox, height: Metrics.iconBox)
            Text(repo)
                .font(LoupeFont.caption)
                .lineLimit(1)
                .offset(y: -0.5)
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 7)
        .frame(height: Metrics.height, alignment: .center)
        .background(Capsule().fill(Color.chipFill))
    }
}

// MARK: - MetricTab
// Selectable folder / risk chips; drives the detail panel on TicketCard.
struct MetricTab: View {
    let symbol: String
    let tint: Color
    let value: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Text("\(value)")
                    .font(LoupeFont.metric)
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: LoupeRadius.chip)
                        .fill(Color.chipFill)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - FileChip
struct FileChip: View {
    let path: String
    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            SetiIconView(path: path, size: LoupeSize.fileIcon)
            Text(name)
                .font(LoupeFont.label)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .offset(y: -1.2)
        }
    }
}

// MARK: - FilesRow
// Single-line file chips; scrolls horizontally across the full ticket width.
struct FilesRow: View {
    let files: [BlueprintFile]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(files.enumerated()), id: \.element.id) { idx, file in
                    HStack(spacing: 8) {
                        if idx > 0 {
                            Circle().fill(Color.textMuted.opacity(0.5)).frame(width: 3, height: 3)
                        }
                        FileChip(path: file.path)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, LoupeSpace.lg)
        }
        .padding(.horizontal, -LoupeSpace.lg)
    }
}

// MARK: - RisksRow
struct RiskChip: View {
    let area: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "light.beacon.max.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.riskAlert)
            Text(area)
                .font(LoupeFont.label)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        }
    }
}

struct RisksRow: View {
    let areas: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(areas.enumerated()), id: \.offset) { idx, area in
                    HStack(spacing: 8) {
                        if idx > 0 {
                            Circle().fill(Color.textMuted.opacity(0.5)).frame(width: 3, height: 3)
                        }
                        RiskChip(area: area)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, LoupeSpace.lg)
        }
        .padding(.horizontal, -LoupeSpace.lg)
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

// MARK: - Home tabs
enum HomeTab: String, CaseIterable, Identifiable, Hashable {
    case tickets, prs
    var id: String { rawValue }
    var title: String { self == .tickets ? "Tickets" : "PRs" }
}

// Liquid-glass segmented switcher with a sliding selection pill.
struct GlassTabSwitcher: View {
    @Binding var selection: HomeTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HomeTab.allCases) { tab in
                segment(tab)
            }
        }
        .animation(.snappy(duration: 0.3), value: selection)
    }

    private func segment(_ tab: HomeTab) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            Text(tab.title)
                .font(LoupeFont.bodyMedium)
                .foregroundStyle(selected ? .white : Color.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background {
                    if selected {
                        Capsule().fill(Color.accent)
                            .matchedGeometryEffect(id: "tabPill", in: ns)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PRRow (PRs tab)
struct PRRow: View {
    let pr: PRSummary
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(pr.reference).font(LoupeFont.code).foregroundStyle(Color.textSecondary)
                        RepoPill(repo: pr.repoLabel)
                    }
                    Text(pr.title)
                        .font(LoupeFont.bodyMedium).foregroundStyle(Color.textPrimary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let author = pr.author {
                        Text("by \(author) · \(pr.updatedAt)")
                            .font(LoupeFont.caption).foregroundStyle(Color.textMuted)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.textMuted)
            }
            .padding(LoupeSpace.lg)
            .background(Color.surface)
        }
        .buttonStyle(.plain)
    }
}

