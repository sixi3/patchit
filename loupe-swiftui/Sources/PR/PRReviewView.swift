import SwiftUI

// MARK: - PRReviewView
// In-app PR review: handoff/body, changed files with diffs, checks, merge/send-back.
struct PRReviewView: View {
    @State var store: PRReviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var showReject = false
    @State private var rejectReason = ""

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                navBar
                content
                if case .loaded = store.phase, let pr = store.pr, !pr.merged {
                    actionBar(pr)
                }
            }
        }
        .task { await store.load() }
        .sheet(isPresented: $showReject) { rejectSheet }
    }

    private var navBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.textPrimary)
            }
            Spacer()
            Text("#\(store.ref.number)").font(LoupeFont.code).foregroundStyle(Color.textMuted)
        }
        .padding(LoupeSpace.lg)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            Spacer(); ProgressView().tint(Color.accent); Spacer()
        case .failed(let m):
            Spacer(); statusText(m, tint: .riskAlert); Spacer()
        case .done(let m):
            Spacer(); statusText(m, tint: .ringHigh); Spacer()
        default:
            if let pr = store.pr { prBody(pr) } else { Spacer() }
        }
    }

    private func prBody(_ pr: PRDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoupeSpace.lg) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if pr.draft { Badge("DRAFT", tint: .textMuted) }
                        Badge(pr.state.uppercased(), tint: pr.merged ? .accent : .ringHigh)
                        if let cs = pr.checkState { Badge(cs.uppercased(), tint: checkTint(cs)) }
                    }
                    Text(pr.title).font(LoupeFont.title).foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        stat("+\(pr.additions ?? 0)", .ringHigh)
                        stat("-\(pr.deletions ?? 0)", .riskAlert)
                        stat("\(pr.changedFiles ?? pr.files.count) files", .textMuted)
                    }
                }

                if !pr.body.isEmpty {
                    section("HANDOFF") {
                        Text(pr.body).font(LoupeFont.body).foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section("CHANGED FILES") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(pr.files) { file in DiffFileView(file: file) }
                    }
                }
            }
            .padding(LoupeSpace.lg)
        }
    }

    private func actionBar(_ pr: PRDetail) -> some View {
        HStack(spacing: 10) {
            Button { showReject = true } label: {
                Text("Reject").font(LoupeFont.button).foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.chipFill))
            }.buttonStyle(.plain)
            Button { Task { await store.merge() } } label: {
                Text(pr.draft ? "Mark ready & merge" : "Merge").font(LoupeFont.button).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.ringHigh))
            }.buttonStyle(.plain)
        }
        .padding(LoupeSpace.lg)
        .background(Color.surface)
    }

    private var rejectSheet: some View {
        VStack(alignment: .leading, spacing: LoupeSpace.lg) {
            Text("Reject pull request").font(LoupeFont.title).foregroundStyle(Color.textPrimary)
            TextField("What needs to change?", text: $rejectReason, axis: .vertical)
                .font(LoupeFont.body).lineLimit(3...6).padding(12)
                .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.surface))
                .overlay(RoundedRectangle(cornerRadius: LoupeRadius.chip).stroke(Color.hairline, lineWidth: 1))
            Button {
                showReject = false
                Task { await store.reject(reason: rejectReason) }
            } label: {
                Text("Reject").font(LoupeFont.button).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.accent))
            }
            .buttonStyle(.plain)
            .disabled(rejectReason.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
        .padding(LoupeSpace.xl)
        .presentationDetents([.medium])
    }

    // helpers
    private func statusText(_ t: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: tint == .riskAlert ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 30)).foregroundStyle(tint)
            Text(t).font(LoupeFont.body).foregroundStyle(Color.textSecondary).multilineTextAlignment(.center)
        }.padding()
    }
    private func stat(_ t: String, _ c: Color) -> some View {
        Text(t).font(LoupeFont.codeStrong).foregroundStyle(c)
    }
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(LoupeFont.label).foregroundStyle(Color.textMuted)
            content()
        }
    }
    private func checkTint(_ s: String) -> Color {
        switch s.lowercased() { case "success", "passing": return .ringHigh
        case "failure", "error": return .riskAlert; default: return .ringMid }
    }
}

// MARK: - Badge / DiffFileView
private struct Badge: View {
    let text: String; let tint: Color
    init(_ text: String, tint: Color) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

private struct DiffFileView: View {
    let file: PRDetail.PRFile
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: file.status == "added" ? "plus.circle.fill"
                          : file.status == "removed" ? "minus.circle.fill" : "pencil.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(statusTint)
                    Text(file.filename).font(LoupeFont.code).foregroundStyle(Color.textPrimary).lineLimit(1)
                    Spacer()
                    Text("+\(file.additions) -\(file.deletions)").font(LoupeFont.code).foregroundStyle(Color.textMuted)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.textMuted)
                }
                .padding(12)
            }
            .buttonStyle(.plain)

            if expanded, !file.patch.isEmpty {
                DiffText(patch: file.patch)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.canvas)
            }
        }
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: LoupeRadius.chip).stroke(Color.hairline, lineWidth: 1))
    }

    private var statusTint: Color {
        switch file.status { case "added": return .ringHigh; case "removed": return .riskAlert; default: return .ringMid }
    }
}

// Renders a unified diff with +/- line coloring.
private struct DiffText: View {
    let patch: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line)).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color(for: line))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func color(for line: Substring) -> Color {
        if line.hasPrefix("+") { return .ringHigh }
        if line.hasPrefix("-") { return .riskAlert }
        if line.hasPrefix("@@") { return .accent }
        return .textSecondary
    }
}
