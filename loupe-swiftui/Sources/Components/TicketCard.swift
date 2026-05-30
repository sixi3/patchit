import SwiftUI

// MARK: - TicketCard
// The inbox card from node 210:18465: priority rail + hatched header, title,
// repo pill, confidence ring + summary, metric strip, file chips, dispatch row.
struct TicketCard: View {
    let item: InboxItem
    var onDispatch: () -> Void = {}
    var onMore: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            // Priority rail
            Rectangle()
                .fill(item.priority.rail)
                .frame(width: LoupeSize.rail)

            VStack(alignment: .leading, spacing: 0) {
                header
                body_
            }
            .background(Color.surface)
        }
        .background(item.priority.wash)   // faint full-card wash
        .clipShape(RoundedRectangle(cornerRadius: LoupeRadius.card))
    }

    // Hatched, priority-tinted top zone
    private var header: some View {
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
        .background(PriorityHeaderBackground(priority: item.priority))
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 6) {
                Text("In").font(LoupeFont.body).foregroundStyle(Color.textMuted)
                RepoPill(repo: item.repo)
            }

            HStack(alignment: .top, spacing: 12) {
                ConfidenceRing(value: item.confidence)
                Text(item.blueprint.summary ?? "")
                    .font(LoupeFont.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                MetricStat(symbol: "folder.fill", tint: Color(hex: 0xE0A33E), value: item.fileCount)
                MetricStat(symbol: "light.beacon.max.fill", tint: .riskAlert, value: item.riskCount)
            }

            if !item.blueprint.files.isEmpty {
                FilesRow(files: item.blueprint.files)
            }

            dispatchRow
        }
        .padding(LoupeSpace.lg)
    }

    private var dispatchRow: some View {
        HStack(spacing: 10) {
            Button(action: onDispatch) {
                HStack(spacing: 8) {
                    Text(item.isReady ? "Dispatch" : "Needs info")
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
}
