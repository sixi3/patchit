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
        // The session is started ONCE by SessionsStore on dispatch and keeps
        // streaming in the background. Opening this view only displays it —
        // it must not re-dispatch or tear down the stream.
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

    private var blocks: [TranscriptBlock] { TranscriptBlock.build(from: store.events) }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(blocks) { block in
                        TranscriptBlockView(
                            block: block,
                            agent: store.harness,
                            isLatest: block.id == blocks.last?.id,
                            sessionRunning: store.isRunning
                        )
                        .id(block.id)
                    }
                }
                .padding(LoupeSpace.lg)
            }
            .onChange(of: store.events.count) {
                if let last = blocks.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
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

// MARK: - Event classification
private extension SessionEvent {
    enum Category { case message, error, milestone, thinking, hidden }

    var category: Category {
        switch type {
        case "agent_message":        return .message
        case "claude":               return kind == "message" ? .message : .thinking
        case "thinking", "action", "codex", "stdout", "stderr", "status", "command":
            return .thinking
        case "error":                return .error
        case "branch":
            return ["committed", "pr_ready", "compare", "pr_failed"].contains(kind ?? "") ? .milestone : .thinking
        case "user_message", "done", "handoff":
            return .hidden            // ticket is in the header; footer/PR handle the rest
        default:                     return .thinking
        }
    }

    /// One readable line for a Thinking step.
    var stepText: String {
        if let text, !text.isEmpty { return text }
        switch type {
        case "status":          return status.map { "Status: \($0)" } ?? "Working…"
        case "codex", "stdout": return "Working…"
        default:                return type
        }
    }
}

// MARK: - TranscriptBlock
struct TranscriptBlock: Identifiable {
    enum Kind { case message, error, milestone, thinking }
    let id: Int
    let kind: Kind
    let events: [SessionEvent]

    /// Group the raw stream: messages/errors/milestones stand alone; runs of
    /// thinking/action events collapse into one accordion block.
    static func build(from events: [SessionEvent]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var pendingThinking: [SessionEvent] = []

        func flushThinking() {
            if let first = pendingThinking.first {
                blocks.append(.init(id: first.id, kind: .thinking, events: pendingThinking))
                pendingThinking.removeAll()
            }
        }

        for event in events {
            switch event.category {
            case .hidden:
                continue
            case .thinking:
                pendingThinking.append(event)
            case .message:
                flushThinking()
                blocks.append(.init(id: event.id, kind: .message, events: [event]))
            case .error:
                flushThinking()
                blocks.append(.init(id: event.id, kind: .error, events: [event]))
            case .milestone:
                flushThinking()
                blocks.append(.init(id: event.id, kind: .milestone, events: [event]))
            }
        }
        flushThinking()
        return blocks
    }
}

// MARK: - Block rendering
private struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let agent: Agent
    let isLatest: Bool
    let sessionRunning: Bool

    var body: some View {
        switch block.kind {
        case .message:   MessageBubble(agent: agent, text: block.events.first?.displayText ?? "")
        case .error:     ErrorBubble(text: block.events.first?.displayText ?? "")
        case .milestone: MilestoneChip(event: block.events.first)
        case .thinking:  ThinkingAccordion(events: block.events, active: isLatest && sessionRunning)
        }
    }
}

private struct MessageBubble: View {
    let agent: Agent
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentGlyph(agent: agent, size: 24)
            Text(text)
                .font(LoupeFont.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ErrorBubble: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.riskAlert)
            Text(text)
                .font(LoupeFont.code)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.riskAlert.opacity(0.08)))
    }
}

private struct MilestoneChip: View {
    let event: SessionEvent?
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.accent)
            Text(event?.displayText ?? "Milestone")
                .font(LoupeFont.caption).foregroundStyle(Color.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.accent.opacity(0.08)))
    }
}

// MARK: - Thinking accordion (collapsed by default; loader doubles as the toggle)
private struct ThinkingAccordion: View {
    let events: [SessionEvent]
    let active: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    if active {
                        ProgressView().controlSize(.mini).tint(Color.textMuted)
                    } else {
                        Image(systemName: "brain")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.textMuted)
                    }
                    Text(active ? "Thinking…" : "Thought · \(events.count) step\(events.count == 1 ? "" : "s")")
                        .font(LoupeFont.caption).foregroundStyle(Color.textMuted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Color.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(events) { event in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(Color.textMuted.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 6)
                            Text(event.stepText)
                                .font(LoupeFont.code)
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.leading, 6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.chipFill.opacity(0.6)))
    }
}
