import SwiftUI

// MARK: - SessionsListView
// Opened from the header pill. Lists dispatched sessions (running first), each
// reopening the live SessionView.
struct SessionsListView: View {
    let sessions: SessionsStore
    let pairing: Pairing
    @Environment(\.dismiss) private var dismiss

    private var ordered: [SessionStore] {
        sessions.sessions.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }   // running first
            return lhs.startedAt > rhs.startedAt
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.sessions.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: LoupeSpace.cardGap) {
                            ForEach(ordered) { session in
                                NavigationLink {
                                    SessionView(store: session, pairing: pairing)
                                } label: {
                                    SessionRow(session: session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(LoupeSpace.screenInset)
                    }
                    .background(Color.canvas)
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 34))
                .foregroundStyle(Color.textMuted)
            Text("No sessions yet")
                .font(LoupeFont.bodyMedium)
                .foregroundStyle(Color.textPrimary)
            Text("Dispatch a ticket and it'll show up here while the agent works.")
                .font(LoupeFont.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
    }
}

private struct SessionRow: View {
    let session: SessionStore

    var body: some View {
        HStack(spacing: 12) {
            AgentGlyph(agent: session.harness, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.item.reference)
                        .font(LoupeFont.code)
                        .foregroundStyle(Color.textSecondary)
                    StatusPill(session: session)
                }
                Text(session.item.title)
                    .font(LoupeFont.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)
            ElapsedLabel(session: session)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.textMuted)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: LoupeRadius.control).stroke(Color.hairline, lineWidth: 1))
    }
}

private struct StatusPill: View {
    let session: SessionStore

    private var color: Color {
        switch session.statusTone {
        case .running:   return Color.accent
        case .prReady:   return Color.onlineDot
        case .completed: return Color.onlineDot
        case .failed:    return Color.riskAlert
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if session.isRunning {
                ProgressView().controlSize(.mini).tint(color)
            }
            Text(session.statusLabel)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct ElapsedLabel: View {
    let session: SessionStore

    var body: some View {
        if session.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(format(context.date.timeIntervalSince(session.startedAt)))
                    .font(LoupeFont.code)
                    .monospacedDigit()
                    .foregroundStyle(Color.textMuted)
            }
        } else {
            Text(format(Date().timeIntervalSince(session.startedAt)))
                .font(LoupeFont.code)
                .monospacedDigit()
                .foregroundStyle(Color.textMuted)
        }
    }

    private func format(_ secs: TimeInterval) -> String {
        let s = Int(max(0, secs))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}
