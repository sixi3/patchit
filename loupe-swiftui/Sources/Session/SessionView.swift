import SwiftUI

// MARK: - SessionView
// Live agent run: dispatch status, streaming transcript, branch/PR surface.
struct SessionView: View {
    @State var store: SessionStore
    let pairing: Pairing
    @Environment(\.dismiss) private var dismiss
    @State private var reviewRef: SessionStore.PRRef?

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.hairline)
                transcript
                footer
            }
        }
        .task { await store.start() }
        .onDisappear { store.cancel() }
        .fullScreenCover(item: $reviewRef) { ref in
            PRReviewView(store: PRReviewStore(ref: ref, pairing: pairing))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                }
                Spacer()
                AgentGlyph(agent: store.harness, size: 24)
                Text(store.harness.label).font(LoupeFont.label).foregroundStyle(Color.textMuted)
            }
            Text(store.item.title)
                .font(LoupeFont.headline).foregroundStyle(Color.textPrimary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let branch = store.branch {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .bold))
                    Text(branch.name).font(LoupeFont.code)
                }.foregroundStyle(Color.textSecondary)
            }
        }
        .padding(LoupeSpace.lg)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.events) { event in
                        EventRow(event: event).id(event.id)
                    }
                }
                .padding(LoupeSpace.lg)
            }
            .onChange(of: store.events.count) {
                if let last = store.events.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            switch store.phase {
            case .dispatching:
                statusPill("Dispatching to your Mac…", system: "paperplane.fill", tint: .accent)
            case .streaming:
                statusPill("Agent is working…", system: "gearshape.2.fill", tint: .accent)
            case .completed(let success):
                if success, let ref = store.prRef {
                    Button { reviewRef = ref } label: {
                        Text("Review changes")
                            .font(LoupeFont.button).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.accent))
                    }.buttonStyle(.plain)
                } else {
                    statusPill(success ? "Completed." : "Finished with no PR.", system: "checkmark.circle.fill", tint: .ringHigh)
                }
            case .failed(let message):
                statusPill(message, system: "exclamationmark.triangle.fill", tint: .riskAlert)
            }
        }
        .padding(LoupeSpace.lg)
        .background(Color.surface)
    }

    private func statusPill(_ text: String, system: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: system).foregroundStyle(tint)
            Text(text).font(LoupeFont.bodyMedium).foregroundStyle(Color.textSecondary)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.chipFill))
    }
}

// MARK: - EventRow
private struct EventRow: View {
    let event: SessionEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(LoupeFont.label).foregroundStyle(tint)
                Text(event.displayText)
                    .font(isCode ? LoupeFont.code : LoupeFont.body)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isCode: Bool { event.type == "stdout" || event.type == "stderr" }

    private var label: String {
        switch event.type {
        case "user_message": return "YOU"
        case "claude":       return "CLAUDE"
        case "codex":        return "CODEX"
        case "stdout":       return "OUTPUT"
        case "stderr":       return "STDERR"
        case "branch":       return "BRANCH"
        case "handoff":      return "HANDOFF"
        case "status":       return "STATUS"
        case "done":         return "DONE"
        case "error":        return "ERROR"
        default:             return event.type.uppercased()
        }
    }

    private var tint: Color {
        switch event.type {
        case "error", "stderr": return .riskAlert
        case "done":            return .ringHigh
        case "branch", "handoff": return .accent
        default:                return .textMuted
        }
    }
}
