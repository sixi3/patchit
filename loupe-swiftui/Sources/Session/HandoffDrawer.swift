import SwiftUI

// MARK: - HandoffDrawer
// Bottom sheet opened from a bento pill. One sheet, body switched by facet —
// the "8 files changed" style detail surface from the mock.
struct HandoffDrawer: View {
    let facet: HandoffFacet
    let summary: HandoffSummary
    let canReview: Bool
    let onReview: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleBlock
                    content
                }
                .padding(LoupeSpace.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Header
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LoupeFont.title)
                .foregroundStyle(Color.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(LoupeFont.code)
                    .foregroundStyle(subtitleTint)
            }
        }
    }

    private var title: String {
        switch facet {
        case .summary: return "Summary"
        case .files:   return summary.files.count == 1 ? "1 file changed" : "\(summary.files.count) files changed"
        case .checks:  return "Checks"
        case .watch:   return "Worth a look"
        case .branch:  return "Branch"
        case .commit:  return summary.prRef != nil ? "Pull request" : "Commit"
        }
    }

    private var subtitle: String? {
        switch facet {
        case .files:
            guard summary.additions > 0 || summary.deletions > 0 else { return nil }
            return "+\(summary.additions) −\(summary.deletions)"
        case .checks:
            let parts = [
                summary.checksPassed.isEmpty ? nil : "\(summary.checksPassed.count) passed",
                summary.checksSkipped.isEmpty ? nil : "\(summary.checksSkipped.count) skipped"
            ].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .branch:
            return summary.baseBranch.map { "base: \($0)" }
        case .commit:
            return summary.repo
        default:
            return nil
        }
    }

    private var subtitleTint: Color {
        facet == .files ? .textSecondary : .textMuted
    }

    // MARK: Body
    @ViewBuilder
    private var content: some View {
        switch facet {
        case .summary: summaryBody
        case .files:   filesBody
        case .checks:  checksBody
        case .watch:   watchBody
        case .branch:  branchBody
        case .commit:  commitBody
        }
    }

    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let tldr = summary.tldr {
                Text(tldr)
                    .font(LoupeFont.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !summary.whatChanged.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(summary.whatChanged.enumerated()), id: \.offset) { _, line in
                        BulletRow(icon: "circle.fill", tint: .accent, text: line)
                    }
                }
            }
        }
    }

    private var filesBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(summary.files) { file in
                SessionDiffFileRow(file: file)
            }
        }
    }

    private var checksBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !summary.checksPassed.isEmpty {
                DrawerSection(label: "Passed") {
                    ForEach(Array(summary.checksPassed.enumerated()), id: \.offset) { _, line in
                        BulletRow(icon: "checkmark.circle.fill", tint: .ringHigh, text: line)
                    }
                }
            }
            if !summary.checksSkipped.isEmpty {
                DrawerSection(label: "Not run") {
                    ForEach(Array(summary.checksSkipped.enumerated()), id: \.offset) { _, line in
                        BulletRow(icon: "minus.circle.fill", tint: .textMuted, text: line)
                    }
                }
            }
        }
    }

    private var watchBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(summary.risks.enumerated()), id: \.offset) { _, line in
                BulletRow(icon: "exclamationmark.triangle.fill", tint: .riskAlert, text: line)
            }
        }
    }

    private var branchBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let branch = summary.branchName {
                InfoTile(icon: "arrow.triangle.branch", label: "Branch", value: branch)
            }
            if let base = summary.baseBranch, !base.isEmpty {
                InfoTile(icon: "arrow.down.to.line", label: "Base", value: base)
            }
            if let repo = summary.repo, !repo.isEmpty {
                InfoTile(icon: "shippingbox.fill", label: "Repo", value: repo)
            }
        }
    }

    private var commitBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pr = summary.prRef {
                InfoTile(icon: "arrow.triangle.pull", label: "Pull request", value: "#\(pr.number)")
                if let repo = summary.repo, !repo.isEmpty {
                    InfoTile(icon: "shippingbox.fill", label: "Repo", value: repo)
                }
            } else if summary.committed {
                InfoTile(icon: "checkmark.seal.fill", label: "Commit", value: "Ready to push")
            }

            VStack(spacing: 10) {
                Button(action: onReview) {
                    Text(canReview ? "Review changes" : "No PR to review")
                        .font(LoupeFont.button)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: LoupeRadius.control)
                            .fill(canReview ? Color.accent : Color.textMuted.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .disabled(!canReview)

                if let url = prURL {
                    ShareLink(item: url) {
                        HStack(spacing: 7) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share PR")
                        }
                        .font(LoupeFont.button)
                        .foregroundStyle(Color.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.accentWash))
                    }
                }
            }
        }
    }

    private var prURL: URL? {
        guard let pr = summary.prRef else { return nil }
        return URL(string: "https://github.com/\(pr.owner)/\(pr.repo)/pull/\(pr.number)")
    }
}

// MARK: - Drawer building blocks
private struct DrawerSection<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(LoupeFont.caption)
                .foregroundStyle(Color.textMuted)
            content
        }
    }
}

private struct BulletRow: View {
    let icon: String
    let tint: Color
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: icon == "circle.fill" ? 6 : 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 18)
            Text(text)
                .font(LoupeFont.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.surface))
    }
}

private struct InfoTile: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.accent)
                .frame(width: 18)
            Text(label)
                .font(LoupeFont.caption)
                .foregroundStyle(Color.textMuted)
            Spacer()
            Text(value)
                .font(LoupeFont.code)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.surface))
    }
}
