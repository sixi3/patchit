import Foundation
import SwiftUI

// MARK: - SessionView
// Live agent run: dispatch status, streaming transcript, branch/PR surface.
struct SessionView: View {
    @State var store: SessionStore
    let pairing: Pairing
    @State private var reviewRef: SessionStore.PRRef?
    @State private var openFacet: HandoffFacet?

    /// Condensed "receipt" derived from the finished run — drives the bento dock.
    private var summary: HandoffSummary { HandoffSummary(store: store) }

    /// Show the sticky handoff dock once the run settles with a real handoff.
    private var showDock: Bool {
        if case .completed = store.phase { return summary.isPresent }
        return false
    }

    private var timelineBlocks: [SessionTimelineBlock] {
        SessionTimelineBlock.build(from: store.events)
    }

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                transcript
                footer
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { sessionToolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showDock {
                HandoffDock(
                    summary: summary,
                    canReview: store.prRef != nil,
                    openFacet: $openFacet,
                    onReview: { if let ref = store.prRef { reviewRef = ref } }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: showDock)
        // The session is started ONCE by SessionsStore on dispatch and keeps
        // streaming in the background. Opening this view only displays it —
        // it must not re-dispatch or tear down the stream.
        .fullScreenCover(item: $reviewRef) { ref in
            PRReviewView(store: PRReviewStore(ref: ref, pairing: pairing))
        }
        .sheet(item: $openFacet) { facet in
            HandoffDrawer(
                facet: facet,
                summary: summary,
                canReview: store.prRef != nil,
                onReview: {
                    openFacet = nil
                    if let ref = store.prRef { reviewRef = ref }
                }
            )
        }
        .modifier(PreviewFacetOpener(openFacet: $openFacet))
    }

    @ToolbarContentBuilder
    private var sessionToolbar: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                sessionToolbarContent
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                sessionToolbarContent
            }
        }
    }

    private var sessionToolbarContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.item.title)
                .font(LoupeFont.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            SessionHeaderMetrics(store: store)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if timelineBlocks.isEmpty {
                        AgentProsePlaceholder(agent: store.harness, isRunning: store.isRunning)
                            .id("waiting")
                    } else {
                        AgentTranscript(
                            agent: store.harness,
                            blocks: timelineBlocks,
                            sessionRunning: store.isRunning
                        )
                    }
                }
                .padding(.top, LoupeSpace.xl)
                .padding(.horizontal, LoupeSpace.xl)
                .padding(.bottom, showDock ? 120 : LoupeSpace.xxl)
            }
            .onChange(of: store.events.count) {
                if let last = timelineBlocks.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch store.phase {
        case .dispatching:
            footerSurface {
                statusPill("Dispatching to your Mac…", system: "paperplane.fill", tint: .accent)
            }
        case .streaming:
            footerSurface {
                statusPill("Agent is working…", system: "gearshape.2.fill", tint: .accent)
            }
        case .completed(let success):
            if summary.isPresent {
                EmptyView()   // the sticky HandoffDock carries the handoff + CTA
            } else if success, let ref = store.prRef {
                footerSurface {
                    Button { reviewRef = ref } label: {
                        Text("Review changes")
                            .font(LoupeFont.button)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.accent))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                footerSurface {
                    statusPill(success ? "Completed." : "Finished with no PR.", system: "checkmark.circle.fill", tint: .ringHigh)
                }
            }
        case .failed(let message):
            footerSurface {
                statusPill(message, system: "exclamationmark.triangle.fill", tint: .riskAlert)
            }
        }
    }

    private func footerSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
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

private struct AgentTranscript: View {
    let agent: Agent
    let blocks: [SessionTimelineBlock]
    let sessionRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentGlyph(agent: agent, size: 28)
                .padding(.top, 1)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    SessionTimelineBlockView(
                        block: block,
                        active: sessionRunning && index == blocks.count - 1
                    )
                    .id(block.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgentProsePlaceholder: View {
    let agent: Agent
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentGlyph(agent: agent, size: 28)
                .padding(.top, 1)
            Text(isRunning ? "Waiting for \(agent.label)..." : "No agent message was captured.")
                .font(LoupeFont.bodyMedium)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SessionHeaderMetrics: View {
    let store: SessionStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 7) {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                Text(formatDuration(store.elapsedDuration))
                if let cost = store.displayCostLabel {
                    Text("•")
                        .foregroundStyle(Color.textMuted.opacity(0.7))
                    Text(cost)
                }
            }
            .font(LoupeFont.caption)
            .foregroundStyle(Color.textSecondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .opacity(store.elapsedDuration > 0 || store.displayCostLabel != nil ? 1 : 0)
        }
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded()))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

}

private struct SessionTimelineBlockView: View {
    let block: SessionTimelineBlock
    let active: Bool

    var body: some View {
        switch block.kind {
        case .prose:
            Text(block.proseText)
                .font(LoupeFont.bodyMedium)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            TimelineAccordion(
                title: active ? "Thinking..." : "Thought for \(block.durationLabel)",
                rows: block.items,
                style: .thought
            )
        case .worked:
            TimelineAccordion(
                title: active ? "Working..." : "Worked for \(block.durationLabel)",
                rows: block.items,
                style: .worked
            )
        case .edit:
            EditFileContainer(block: block)
        }
    }
}

private struct TimelineAccordion: View {
    enum Style { case thought, worked }

    let title: String
    let rows: [StreamTranscriptItem]
    let style: Style
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(LoupeFont.bodyMedium)
                        .foregroundStyle(Color.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                LazyVStack(alignment: .leading, spacing: style == .thought ? 8 : 9) {
                    ForEach(rows) { item in
                        switch style {
                        case .thought:
                            ThoughtTextBlock(text: item.event.displayText)
                        case .worked:
                            WorkedActionRow(item: item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EditFileContainer: View {
    let block: SessionTimelineBlock

    private var filePath: String? { block.items.first?.editFilePath }
    private var fileName: String { block.items.first?.editFileName ?? "file" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 4) {
                Text("Edited")
                    .font(LoupeFont.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                HStack(alignment: .center, spacing: 2) {
                    if let filePath {
                        SetiIconView(path: filePath, size: 17)
                    }
                    Text(fileName)
                        .font(LoupeFont.bodyMedium)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(block.items) { item in
                    EditChangeRow(item: item)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LoupeRadius.control)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xFFFFFF), Color(hex: 0xEBE9E5)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: LoupeRadius.control)
                .stroke(Color(hex: 0xD9D7D3, alpha: 0.5), lineWidth: 1)
        )
    }
}

private struct EditChangeRow: View {
    let item: StreamTranscriptItem
    @State private var expanded = false

    private var canExpand: Bool { item.diffPatch != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard canExpand else { return }
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 6) {
                    editStats
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.editSummary ?? "Updated \(item.editFileName).")
                            .font(LoupeFont.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                        if let lineRange = item.editLineRange {
                            HStack(spacing: 4) {
                                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(lineRange)
                            }
                            .font(LoupeFont.caption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.textMuted)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let patch = item.diffPatch {
                SessionDiffText(patch: patch)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.surface))
        .overlay(
            RoundedRectangle(cornerRadius: LoupeRadius.chip)
                .stroke(Color(hex: 0xD9D7D3, alpha: 0.5), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var editStats: some View {
        if let stats = item.editStats {
            HStack(spacing: 3) {
                Text("+\(stats.additions)")
                    .foregroundStyle(Color.ringHigh)
                Text("/")
                    .foregroundStyle(Color.textMuted)
                Text("-\(stats.deletions)")
                    .foregroundStyle(Color.riskAlert)
            }
            .font(LoupeFont.bodyMedium)
            .lineLimit(1)
        } else {
            Text("+0 / -0")
                .font(LoupeFont.bodyMedium)
                .foregroundStyle(Color.textMuted)
        }
    }
}

private struct ThoughtTextBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(LoupeFont.body)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.chipFill.opacity(0.75)))
    }
}

private struct WorkedActionRow: View {
    let item: StreamTranscriptItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.event.actionPillIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.event.actionPillTint)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.event.accordionTitle)
                    .font(LoupeFont.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                if let summary = item.resultSummary {
                    Text(summary)
                        .font(LoupeFont.caption)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptEventRow: View {
    let item: StreamTranscriptItem

    var body: some View {
        if item.isProse {
            Text(item.event.displayText)
                .font(LoupeFont.bodyMedium)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            InlineToolRow(item: item)
        }
    }
}

private struct InlineToolRow: View {
    let item: StreamTranscriptItem
    @State private var expanded = false

    private var canExpand: Bool {
        item.diffPatch != nil || item.resultSummary != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canExpand {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    header(showsChevron: true, expanded: expanded)
                }
                .buttonStyle(.plain)

                if expanded, let patch = item.diffPatch {
                    SessionDiffText(patch: patch)
                        .padding(.top, 2)
                } else if expanded, let summary = item.resultSummary {
                    Text(summary)
                        .font(LoupeFont.caption)
                        .foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 1)
                }
            } else {
                header(showsChevron: false, expanded: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.chipFill))
    }

    @ViewBuilder
    private func header(showsChevron: Bool, expanded: Bool) -> some View {
        if item.isEdit {
            editHeader(showsChevron: showsChevron, expanded: expanded)
        } else {
            standardHeader(showsChevron: showsChevron, expanded: expanded)
        }
    }

    private func standardHeader(showsChevron: Bool, expanded: Bool) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: item.event.actionPillIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.event.actionPillTint)
                .frame(width: 18, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.event.accordionTitle)
                    .font(LoupeFont.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.textMuted)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
    }

    private func editHeader(showsChevron: Bool, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: item.event.actionPillIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.event.actionPillTint)
                    .frame(width: 18, height: 20)
                Text("Edited")
                    .font(LoupeFont.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                HStack(alignment: .center, spacing: 0) {
                    if let path = item.editFilePath {
                        SetiIconView(path: path, size: 17)
                    }
                    Text(item.editFileName)
                        .font(LoupeFont.bodyMedium)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                editStats
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            if let summary = item.editSummary {
                Text(summary)
                    .font(LoupeFont.caption)
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var editStats: some View {
        if let stats = item.editStats {
            HStack(spacing: 3) {
                if stats.additions > 0 {
                    Text("+\(stats.additions)")
                        .foregroundStyle(Color.ringHigh)
                }
                if stats.deletions > 0 {
                    Text("-\(stats.deletions)")
                        .foregroundStyle(Color.riskAlert)
                }
            }
            .font(LoupeFont.bodyMedium)
            .lineLimit(1)
        }
    }
}

private struct StreamTranscriptItem: Identifiable {
    let id: Int
    let event: SessionEvent
    var result: SessionEvent?

    var isProse: Bool { event.isTranscriptProse }
    var isEdit: Bool { event.isTranscriptEditAction }
    var isThought: Bool { event.isTranscriptThought }
    var isWork: Bool { !isProse && !isEdit && !isThought }
    var editSummary: String? { event.editSummaryText(result: result) }
    var editFileName: String { event.editFileName }
    var editFilePath: String? { event.filePath }
    var editStats: (additions: Int, deletions: Int)? { event.diffStats(result: result) }
    var editLineRange: String? { event.editLineRange(result: result) }
    var resultSummary: String? { result?.resultSummaryText }
    var diffPatch: String? {
        if let patch = event.patch, !patch.isEmpty { return patch }
        if let patch = result?.patch, !patch.isEmpty { return patch }
        return nil
    }

    static func build(from events: [SessionEvent]) -> [StreamTranscriptItem] {
        var seenProse = Set<String>()
        var items: [StreamTranscriptItem] = []
        var capturedHandoff = false

        func attach(_ result: SessionEvent) {
            if let toolUseId = result.toolUseId,
               let exactIndex = items.lastIndex(where: { $0.event.toolUseId == toolUseId }) {
                items[exactIndex].result = result
                return
            }
            if let lastToolIndex = items.indices.reversed().first(where: { !items[$0].isProse && items[$0].result == nil }) {
                items[lastToolIndex].result = result
            }
        }

        for event in events {
            if event.type == "handoff" {
                capturedHandoff = true
                continue
            }
            if event.isTranscriptHidden { continue }
            if event.isTranscriptProse {
                if capturedHandoff { continue }
                let key = event.displayText.normalizedTranscriptText
                guard seenProse.insert(key).inserted else { continue }
                items.append(StreamTranscriptItem(id: event.id, event: event))
            } else if event.isTranscriptToolResult {
                attach(event)
            } else if event.isTranscriptThought || event.isTranscriptToolCall {
                items.append(StreamTranscriptItem(id: event.id, event: event))
            }
        }
        return items
    }
}

private struct SessionTimelineBlock: Identifiable {
    enum Kind: Equatable { case prose, thought, worked, edit }

    let id: String
    let kind: Kind
    let items: [StreamTranscriptItem]

    var proseText: String { items.first?.event.displayText ?? "" }

    var durationLabel: String {
        let dates = items.compactMap(\.event.eventDate)
        let interval: TimeInterval
        if let first = dates.first, let last = dates.last {
            interval = max(1, last.timeIntervalSince(first))
        } else {
            interval = 1
        }
        return Self.format(interval)
    }

    static func build(from events: [SessionEvent]) -> [SessionTimelineBlock] {
        let transcriptItems = StreamTranscriptItem.build(from: events)
        var blocks: [SessionTimelineBlock] = []
        var pendingThought: [StreamTranscriptItem] = []
        var pendingWork: [StreamTranscriptItem] = []

        func flushThought() {
            guard let first = pendingThought.first else { return }
            blocks.append(.init(id: "thought-\(first.id)", kind: .thought, items: pendingThought))
            pendingThought.removeAll()
        }

        func flushWork() {
            guard let first = pendingWork.first else { return }
            blocks.append(.init(id: "worked-\(first.id)", kind: .worked, items: pendingWork))
            pendingWork.removeAll()
        }

        func appendWork(_ item: StreamTranscriptItem) {
            if pendingWork.last?.event.timelineDedupeKey == item.event.timelineDedupeKey { return }
            pendingWork.append(item)
        }

        func appendEdit(_ item: StreamTranscriptItem) {
            guard let last = blocks.last,
                  last.kind == .edit,
                  last.editFilePath == item.editFilePath else {
                blocks.append(.init(id: "edit-\(item.id)", kind: .edit, items: [item]))
                return
            }
            if last.items.last?.event.editDedupeKey == item.event.editDedupeKey { return }
            var nextItems = last.items
            nextItems.append(item)
            blocks.removeLast()
            blocks.append(.init(id: last.id, kind: .edit, items: nextItems))
        }

        for item in transcriptItems {
            if item.isProse {
                flushThought()
                flushWork()
                blocks.append(.init(id: "prose-\(item.id)", kind: .prose, items: [item]))
            } else if item.isEdit {
                flushThought()
                flushWork()
                appendEdit(item)
            } else if item.isThought {
                flushWork()
                pendingThought.append(item)
            } else {
                flushThought()
                appendWork(item)
            }
        }
        flushThought()
        flushWork()
        return blocks
    }

    var editFilePath: String? {
        items.first?.editFilePath
    }

    private static func format(_ value: TimeInterval) -> String {
        let seconds = max(1, Int(value.rounded()))
        let minutes = seconds / 60
        let secs = seconds % 60
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}

// MARK: - Preview facet opener
// DEBUG-only: `-LoupePreviewFacet <facet>` auto-opens a handoff drawer so the
// bento drawers can be screenshotted deterministically. No-op in release.
private struct PreviewFacetOpener: ViewModifier {
    @Binding var openFacet: HandoffFacet?

    func body(content: Content) -> some View {
        #if DEBUG
        content.onAppear {
            guard let index = CommandLine.arguments.firstIndex(of: "-LoupePreviewFacet"),
                  index + 1 < CommandLine.arguments.count,
                  let facet = HandoffFacet(rawValue: CommandLine.arguments[index + 1]) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openFacet = facet }
        }
        #else
        content
        #endif
    }
}

// MARK: - Event classification
private extension SessionEvent {
    enum Category { case message, error, milestone, handoff, fileChange, activity, runner, hidden }

    var isNativeAgentProse: Bool {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if type == "agent_message" { return true }
        if type == "claude", kind == "message" { return true }
        return false
    }

    var isTranscriptProse: Bool {
        isNativeAgentProse
    }

    var isTranscriptThought: Bool {
        type == "thinking"
    }

    var isTranscriptHidden: Bool {
        if ["user_message", "done", "handoff", "deviations_computed", "status"].contains(type) { return true }
        if type == "branch" { return true }
        if type == "claude", ["thread_start", "result"].contains(kind ?? "") { return true }
        return false
    }

    var isTranscriptToolCall: Bool {
        if type == "error" { return true }
        if type == "file_change" { return true }
        if type == "action" { return true }
        if type == "command" { return true }
        if type == "claude" {
            if kind == "tool_use", ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(toolName ?? "") {
                return false
            }
            return ["tool_use", "file_change", "retry"].contains(kind ?? "")
        }
        return false
    }

    var isTranscriptToolResult: Bool {
        type == "stdout" || type == "stderr" || (type == "claude" && kind == "tool_result")
    }

    var isTranscriptEditAction: Bool {
        if type == "file_change" { return true }
        if type == "action", tool == "edit" { return true }
        if type == "claude", kind == "file_change" { return true }
        return false
    }

    var accordionTitle: String {
        let title = [actionVerb, actionObject].compactMap(\.self).joined(separator: " ")
        return title.isEmpty ? accordionVerb : title
    }

    func editSummaryText(result: SessionEvent?) -> String? {
        guard isTranscriptEditAction else { return nil }
        guard let stats = diffStats(result: result) else { return "Updated \(editFileName)." }
        if stats.additions > 0, stats.deletions > 0 {
            return "Updated \(editFileName) with \(stats.additions) added and \(stats.deletions) removed line\(stats.deletions == 1 ? "" : "s")."
        }
        if stats.additions > 0 {
            return "Added \(stats.additions) line\(stats.additions == 1 ? "" : "s") to \(editFileName)."
        }
        if stats.deletions > 0 {
            return "Removed \(stats.deletions) line\(stats.deletions == 1 ? "" : "s") from \(editFileName)."
        }
        return "Updated \(editFileName)."
    }

    var resultSummaryText: String? {
        if isError == true { return detailText.compactTranscriptResult }
        if let output, !output.isEmpty { return output.compactTranscriptResult }
        if let text, !text.isEmpty { return text.stripToolNamePrefix(toolName).compactTranscriptResult }
        return nil
    }

    var actionPillIcon: String {
        if type == "error" { return "exclamationmark.octagon.fill" }
        if type == "action", tool == "shell" { return "terminal" }
        if isTranscriptEditAction { return "pencil" }
        if type == "claude", kind == "retry" { return "arrow.clockwise" }
        if type == "claude", kind == "tool_use" {
            switch toolName {
            case "Read": return "doc.text.magnifyingglass"
            case "Grep", "Glob": return "magnifyingglass"
            case "Bash": return "terminal"
            default: return "wrench.and.screwdriver.fill"
            }
        }
        return "circle.fill"
    }

    var actionPillTint: Color {
        if type == "error" || isError == true { return .riskAlert }
        return .accent
    }

    private var accordionVerb: String {
        actionVerb
    }

    private var actionVerb: String {
        if type == "error" { return "Error" }
        if type == "file_change" { return "Edited" }
        if type == "action", tool == "shell" { return shellActionTitle.verb }
        if type == "action", tool == "edit" { return "Edited" }
        if type == "claude", kind == "file_change" { return "Edited" }
        if type == "claude", kind == "retry" { return "Retrying" }
        if type == "claude", kind == "tool_use" {
            switch toolName {
            case "Read": return "Read"
            case "Grep": return "Searched"
            case "Glob": return "Found"
            case "Bash": return shellActionTitle.verb
            case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Edited"
            case let name?: return name
            case nil: return "Used tool"
            }
        }
        return actionTitle
    }

    private var accordionObject: String? {
        actionObject
    }

    private var actionObject: String? {
        if type == "action", tool == "shell" { return shellActionTitle.object }
        if let filePath { return filePath.condensedPathDisplay }
        if type == "claude", kind == "tool_use", let toolName {
            switch toolName {
            case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit":
                return toolInputPath?.condensedPathDisplay
            case "Grep", "Glob":
                return toolInputPattern ?? toolInputPath?.condensedPathDisplay
            case "Bash":
                return shellActionTitle.object
            default:
                return toolInputSummary
            }
        }
        return toolInputSummary
    }

    var editFileName: String {
        filePath.map { ($0 as NSString).lastPathComponent } ?? "file"
    }

    func diffStats(result: SessionEvent?) -> (additions: Int, deletions: Int)? {
        let patchStats = (patch ?? result?.patch).diffLineStats
        let added = additions ?? patchStats.additions
        let removed = deletions ?? patchStats.deletions
        guard added != 0 || removed != 0 else { return nil }
        return (added, removed)
    }

    func editLineRange(result: SessionEvent?) -> String? {
        let range = (patch ?? result?.patch).diffLineRange
        guard let range else { return nil }
        return "Ln \(range)"
    }

    private var shellActionTitle: (verb: String, object: String?) {
        let command = (input ?? text ?? "").stripToolNamePrefix(toolName).stripCommandPrefix.lowercased()
        if command.contains("xcodebuild") {
            if command.contains("-list") { return ("Checked", "Xcode schemes") }
            if command.contains("build") { return ("Ran", "build") }
            return ("Checked", "Xcode")
        }
        if command.contains("grep") || command.contains("rg ") {
            return ("Searched", nil)
        }
        if command.contains("git status") { return ("Checked", "git status") }
        if command.contains("git diff") { return ("Checked", "diff") }
        if command.contains("git log") { return ("Checked", "git history") }
        if command.contains("npm test") || command.contains("pnpm test") || command.contains("yarn test") {
            return ("Ran", "tests")
        }
        if command.contains("npm run") || command.contains("pnpm ") || command.contains("yarn ") {
            return ("Ran", "script")
        }
        return ("Ran", "command")
    }

    var isToolActivity: Bool {
        if type == "action", tool == "shell" || tool == "edit" { return true }
        if type == "claude", kind == "tool_use" { return true }
        if type == "command" { return true }
        return false
    }

    var isCommandToolEvent: Bool {
        type == "command" || (type == "action" && tool == "shell") || (type == "claude" && toolName == "Bash")
    }

    var isEditToolEvent: Bool {
        (type == "action" && tool == "edit") || (type == "claude" && ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(toolName ?? ""))
    }

    static func coalescedToolActivity(from events: [SessionEvent]) -> [SessionEvent] {
        var seen = Set<String>()
        var result: [SessionEvent] = []
        for event in events where event.isToolActivity {
            let key = event.toolActivityKey
            guard seen.insert(key).inserted else { continue }
            result.append(event)
        }
        return result
    }

    private var toolActivityKey: String {
        [
            type,
            kind ?? "",
            tool ?? "",
            toolName ?? "",
            path ?? "",
            detailText
        ].joined(separator: "|")
    }

    var timelineDedupeKey: String {
        [
            type,
            kind ?? "",
            tool ?? "",
            toolName ?? "",
            filePath ?? "",
            (input ?? text ?? output ?? "").stripCommandPrefix.normalizedTranscriptText
        ].joined(separator: "|")
    }

    var editDedupeKey: String {
        [
            type,
            kind ?? "",
            tool ?? "",
            toolName ?? "",
            filePath ?? "",
            "\(additions ?? -1)",
            "\(deletions ?? -1)",
            patch ?? "",
            (input ?? text ?? "").normalizedTranscriptText
        ].joined(separator: "|")
    }

    var eventDate: Date? {
        guard let at else { return nil }
        return ISO8601DateFormatter().date(from: at)
    }

    var category: Category {
        switch type {
        case "agent_message":        return .message
        case "file_change":          return .fileChange
        case "claude":
            switch kind {
            case "message":     return .message
            case "file_change": return .fileChange
            case "tool_result": return isError == true ? .error : .activity
            case "tool_use", "retry": return .activity
            case "thread_start", "result": return isError == true ? .error : .hidden
            default:            return .activity
            }
        case "action":
            return tool == "edit" ? .fileChange : .activity
        case "thinking", "codex", "stdout", "stderr", "status":
            return .activity
        case "command":
            return .runner
        case "error":                return .error
        case "branch":
            return ["created", "committed", "pr_ready", "compare", "pr_failed", "push_failed", "no_changes"].contains(kind ?? "") ? .milestone : .activity
        case "handoff":
            return .handoff
        case "deviations_computed":
            return .milestone
        case "user_message", "done":
            return .hidden
        default:                     return .activity
        }
    }

    var actionTitle: String {
        if type == "command" { return "Runner started \(toolName ?? "agent")" }
        if type == "thinking" { return "Thought" }
        if type == "status" { return "Status" }
        if type == "stdout" { return "Output" }
        if type == "stderr" { return "Error output" }
        if type == "action", tool == "shell" { return "Ran command" }
        if type == "action", tool == "edit" { return "Edited files" }
        if type == "claude", kind == "tool_use" { return toolTitle }
        if type == "claude", kind == "tool_result" { return isError == true ? "Tool failed" : "Tool result" }
        if type == "claude", kind == "result" { return "Run summary" }
        return kind?.replacingOccurrences(of: "_", with: " ").capitalized ?? type.capitalized
    }

    var detailText: String {
        if let text, !text.isEmpty { return text }
        if let output, !output.isEmpty { return output }
        if let input, !input.isEmpty { return input }
        switch type {
        case "status":          return status.map { "Status: \($0)" } ?? "Working…"
        case "codex", "stdout": return "Working"
        default:                return type
        }
    }

    var filePath: String? {
        if let path, !path.isEmpty { return path }
        let textPath = text?.replacingOccurrences(of: "Edited ", with: "")
        return textPath?.contains("/") == true || textPath?.contains(".") == true ? textPath : nil
    }

    var isFileChangeEvent: Bool {
        if type == "file_change" { return true }
        if type == "claude", kind == "file_change" { return true }
        if type == "action", tool == "edit" { return true }
        return false
    }

    var isAuthoritativeFileChange: Bool {
        type == "file_change" && kind == "git_diff"
    }

    var fileStatus: String {
        if let status, !status.isEmpty { return status }
        if let changeKind, changeKind == "write" { return "added" }
        return "modified"
    }

    var toolTitle: String {
        switch toolName {
        case "Read": return "Opened file"
        case "Grep": return "Searched text"
        case "Glob": return "Found files"
        case "Bash": return "Ran command"
        case "Edit", "MultiEdit", "Write": return "Edited file"
        case let name?: return name
        case nil: return "Used tool"
        }
    }

    private var toolInputSummary: String? {
        if let input, !input.isEmpty { return input.stripCommandPrefix }
        if let text, !text.isEmpty { return text.stripToolNamePrefix(toolName) }
        return nil
    }

    private var toolInputPath: String? {
        let source = input ?? text ?? ""
        let candidates = source.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "," || $0 == ":" })
            .map(String.init)
        return candidates.first { $0.contains("/") || $0.contains(".swift") || $0.contains(".js") || $0.contains(".ts") || $0.contains(".tsx") }
    }

    private var toolInputPattern: String? {
        let source = (input ?? text ?? "").stripToolNamePrefix(toolName)
        if source.isEmpty { return nil }
        if let path = toolInputPath {
            return source.replacingOccurrences(of: path, with: "").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        return source.nilIfEmpty
    }

}

private extension String {
    var normalizedTranscriptText: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    var stripCommandPrefix: String {
        if hasPrefix("$ ") { return String(dropFirst(2)) }
        return self
    }

    func stripToolNamePrefix(_ toolName: String?) -> String {
        guard let toolName, hasPrefix("\(toolName):") else { return self }
        return String(dropFirst(toolName.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var condensedPathDisplay: String {
        let home = NSHomeDirectory()
        var value = replacingOccurrences(of: home, with: "~")
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 4 {
            value = [parts[0], "...", parts[parts.count - 2], parts[parts.count - 1]]
                .map(String.init)
                .joined(separator: "/")
        }
        return value
    }

    var compactTranscriptResult: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "(Bash completed with no output)" { return "Completed with no output." }
        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        let suffix = lines.count > 1 ? " + \(lines.count - 1) more line\(lines.count == 2 ? "" : "s")" : ""
        return String(first.prefix(180)) + suffix
    }
}

private extension Optional where Wrapped == String {
    var diffLineStats: (additions: Int, deletions: Int) {
        guard let self, !self.isEmpty else { return (0, 0) }
        var additions = 0
        var deletions = 0
        for line in self.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 }
            if line.hasPrefix("-") { deletions += 1 }
        }
        return (additions, deletions)
    }

    var diffLineRange: String? {
        guard let self, !self.isEmpty else { return nil }
        let pattern = #"@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(self.startIndex..<self.endIndex, in: self)
        let matches = regex.matches(in: self, range: nsRange)
        let ranges: [(start: Int, end: Int)] = matches.compactMap { match in
            guard let startRange = Range(match.range(at: 1), in: self),
                  let start = Int(self[startRange]) else { return nil }
            let count: Int
            if match.range(at: 2).location != NSNotFound,
               let countRange = Range(match.range(at: 2), in: self),
               let parsed = Int(self[countRange]) {
                count = parsed
            } else {
                count = 1
            }
            return (start, max(start, start + max(0, count - 1)))
        }
        guard let first = ranges.first else { return nil }
        let start = ranges.map(\.start).min() ?? first.start
        let end = ranges.map(\.end).max() ?? first.end
        return start == end ? "\(start)" : "\(start)-\(end)"
    }
}

// MARK: - TranscriptBlock
struct TranscriptBlock: Identifiable {
    enum Kind { case message, error, milestone, handoff, fileChanges, activity, runner }
    let id: Int
    let kind: Kind
    let events: [SessionEvent]

    /// Group the raw stream into mobile-scannable work journal cards.
    static func build(from events: [SessionEvent]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var pendingActivity: [SessionEvent] = []
        var pendingFiles: [SessionEvent] = []

        func flushActivity() {
            if let first = pendingActivity.first {
                blocks.append(.init(id: first.id, kind: .activity, events: pendingActivity))
                pendingActivity.removeAll()
            }
        }

        func flushFiles() {
            if let first = pendingFiles.first {
                blocks.append(.init(id: first.id, kind: .fileChanges, events: pendingFiles))
                pendingFiles.removeAll()
            }
        }

        for event in events {
            switch event.category {
            case .hidden:
                continue
            case .activity:
                pendingActivity.append(event)
            case .fileChange:
                flushActivity()
                pendingFiles.append(event)
            case .runner:
                flushActivity()
                flushFiles()
                blocks.append(.init(id: event.id, kind: .runner, events: [event]))
            case .message:
                flushActivity()
                flushFiles()
                blocks.append(.init(id: event.id, kind: .message, events: [event]))
            case .error:
                flushActivity()
                flushFiles()
                blocks.append(.init(id: event.id, kind: .error, events: [event]))
            case .milestone:
                flushActivity()
                flushFiles()
                blocks.append(.init(id: event.id, kind: .milestone, events: [event]))
            case .handoff:
                flushActivity()
                flushFiles()
                blocks.append(.init(id: event.id, kind: .handoff, events: [event]))
            }
        }
        flushActivity()
        flushFiles()
        return blocks
    }
}

// MARK: - Block rendering
private struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let agent: Agent
    let isLatest: Bool
    let sessionRunning: Bool
    let canReview: Bool
    let onReview: () -> Void

    var body: some View {
        switch block.kind {
        case .message:
            TimelineItem(agent: agent, showsConnector: true) {
                MessageBubble(agent: agent, text: block.events.first?.displayText ?? "")
            }
        case .error:
            TimelineItem(icon: "exclamationmark.octagon.fill", tint: .riskAlert, showsConnector: true) {
                ErrorCard(text: block.events.first?.displayText ?? "")
            }
        case .milestone:
            TimelineItem(icon: milestoneIcon, tint: milestoneTint, showsConnector: true) {
                MilestoneCard(event: block.events.first)
            }
        case .handoff:
            // The handoff now lives in the sticky HandoffDock, not inline in the timeline.
            EmptyView()
        case .fileChanges:
            TimelineItem(icon: "doc.text.fill", tint: .accent, showsConnector: true) {
                DiffSummaryCard(events: block.events)
            }
        case .activity:
            TimelineItem(icon: activityIcon, tint: .accent, showsConnector: true) {
                ActivityCard(events: block.events, active: isLatest && sessionRunning)
            }
        case .runner:
            TimelineItem(icon: "terminal.fill", tint: .accent, showsConnector: true) {
                RunnerCard(event: block.events.first)
            }
        }
    }

    private var milestoneIcon: String {
        switch block.events.first?.kind {
        case "created": return "arrow.triangle.branch"
        case "committed": return "checkmark.seal.fill"
        case "pr_ready": return "arrow.triangle.pull"
        case "push_failed", "pr_failed": return "exclamationmark.triangle.fill"
        default: return "sparkles"
        }
    }

    private var milestoneTint: Color {
        switch block.events.first?.kind {
        case "push_failed", "pr_failed": return .riskAlert
        default: return .accent
        }
    }

    private var activityIcon: String {
        block.events.contains(where: { $0.type == "thinking" }) ? "bubble.left.fill" : "gearshape.2.fill"
    }
}

private struct TimelineItem<Content: View>: View {
    let icon: String?
    let tint: Color
    let showsConnector: Bool
    let agent: Agent?
    @ViewBuilder let content: Content

    init(icon: String, tint: Color, showsConnector: Bool = true, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.tint = tint
        self.showsConnector = showsConnector
        self.agent = nil
        self.content = content()
    }

    init(agent: Agent, showsConnector: Bool = true, @ViewBuilder content: () -> Content) {
        self.icon = nil
        self.tint = .accent
        self.showsConnector = showsConnector
        self.agent = agent
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                iconView
                    .frame(width: 30, height: 30)
                if showsConnector {
                    Rectangle()
                        .fill(Color.accent.opacity(0.18))
                        .frame(width: 1)
                        .frame(minHeight: 54)
                }
            }
            content
                .padding(.top, 3)
                .padding(.bottom, showsConnector ? 18 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let agent {
            AgentGlyph(agent: agent, size: 30)
        } else if let icon {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

private struct CompactSessionTicket: View {
    let item: InboxItem

    var body: some View {
        HStack(spacing: 0) {
            item.priority.rail
                .frame(width: 7)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    PriorityGlyphs(type: item.issueType, priority: item.priority)
                    Text(item.reference)
                        .font(LoupeFont.code)
                        .foregroundStyle(Color.textSecondary)
                }
                Text(item.title)
                    .font(LoupeFont.headline)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PriorityHeaderBackground(priority: item.priority))
    }
}

private struct MessageBubble: View {
    let agent: Agent
    let text: String
    var body: some View {
        Text(text)
            .font(LoupeFont.bodyMedium)
            .foregroundStyle(Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ErrorCard: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Error")
                .font(LoupeFont.bodyMedium)
                .foregroundStyle(Color.textPrimary)
            Text(text)
                .font(LoupeFont.code)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MilestoneCard: View {
    let event: SessionEvent?
    private var tint: Color {
        if event?.kind == "push_failed" || event?.kind == "pr_failed" { return .riskAlert }
        return .accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(LoupeFont.bodyMedium)
                .foregroundStyle(Color.textPrimary)
            if let detail {
                Text(detail)
                    .font(LoupeFont.body)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch event?.kind {
        case "created": return "Branch created"
        case "committed": return "Commit created"
        case "pr_ready": return "PR ready"
        case "no_changes": return "No changes"
        case "push_failed": return "Push failed"
        case "pr_failed": return "PR creation failed"
        default: return event?.type == "handoff" ? "Handoff ready" : "Milestone"
        }
    }

    private var detail: String? {
        if let pr = event?.prNumber { return "#\(pr) · \(event?.repo ?? "")" }
        if let branch = event?.branch { return branch }
        return event?.displayText
    }
}

private struct DiffSummaryCard: View {
    let events: [SessionEvent]

    private var files: [SessionFileChange] {
        SessionFileChange.coalesced(from: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(system: "doc.text.fill", title: "Diff", subtitle: diffSummary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(files.prefix(5)) { file in
                    SessionDiffFileRow(file: file)
                }
                if files.count > 5 {
                    Text("+\(files.count - 5) more")
                        .font(LoupeFont.caption)
                        .foregroundStyle(Color.textMuted)
                }
            }
        }
    }

    private var diffSummary: String {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        if additions > 0 || deletions > 0 {
            return "+\(additions) -\(deletions)"
        }
        return "\(files.count) file\(files.count == 1 ? "" : "s")"
    }
}

struct SessionFileChange: Identifiable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String?

    var id: String { path }
    var filename: String { (path as NSString).lastPathComponent }
    var parent: String { path.deletingLastPathComponentDisplay }
    var hasPatch: Bool { patch?.isEmpty == false }

    static func coalesced(from events: [SessionEvent]) -> [SessionFileChange] {
        let fileEvents = events.filter(\.isFileChangeEvent)
        let authoritative = fileEvents.filter(\.isAuthoritativeFileChange)
        let sourceEvents = authoritative.isEmpty ? fileEvents : authoritative
        var byPath: [String: SessionFileChange] = [:]
        for event in sourceEvents {
            guard let path = event.filePath else { continue }
            let existing = byPath[path]
            byPath[path] = SessionFileChange(
                path: path,
                status: event.fileStatus,
                additions: (existing?.additions ?? 0) + (event.additions ?? 0),
                deletions: (existing?.deletions ?? 0) + (event.deletions ?? 0),
                patch: event.patch?.isEmpty == false ? event.patch : existing?.patch
            )
        }
        return byPath.values.sorted { $0.path < $1.path }
    }
}

struct SessionDiffFileRow: View {
    let file: SessionFileChange
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard file.hasPatch else { return }
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 18, height: 18)
                    SetiIconView(path: file.path, size: 17)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.filename)
                            .font(LoupeFont.code)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        if !file.parent.isEmpty {
                            Text(file.parent)
                                .font(LoupeFont.caption)
                                .foregroundStyle(Color.textMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if file.additions > 0 || file.deletions > 0 {
                        HStack(spacing: 4) {
                            if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(Color.ringHigh) }
                            if file.deletions > 0 { Text("-\(file.deletions)").foregroundStyle(Color.riskAlert) }
                        }
                        .font(LoupeFont.code)
                    }
                    if file.hasPatch {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.textMuted)
                    }
                }
                .padding(10)
            }
            .buttonStyle(.plain)

            if expanded, let patch = file.patch {
                SessionDiffText(patch: patch)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.chipFill))
    }

    private var icon: String {
        switch file.status {
        case "added": return "plus.circle.fill"
        case "removed": return "minus.circle.fill"
        default: return "pencil.circle.fill"
        }
    }

    private var tint: Color {
        switch file.status {
        case "added": return .ringHigh
        case "removed": return .riskAlert
        default: return .ringMid
        }
    }
}

struct SessionDiffText: View {
    let patch: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: LoupeRadius.chip).stroke(Color.hairline, lineWidth: 1))
    }

    private var lines: [String] {
        patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") { return .ringHigh }
        if line.hasPrefix("-") { return .riskAlert }
        if line.hasPrefix("@@") { return .accent }
        return .textSecondary
    }
}

private struct ActivityCard: View {
    let events: [SessionEvent]
    let active: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    if active {
                        ProgressView().controlSize(.mini).tint(Color.accent)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.accent)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(active ? "Working…" : title)
                            .font(LoupeFont.bodyMedium).foregroundStyle(Color.textPrimary)
                        Text(summary)
                            .font(LoupeFont.caption).foregroundStyle(Color.textMuted)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Color.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(events) { event in
                        ActivityRow(event: event)
                    }
                }
                .padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        if events.contains(where: { $0.type == "thinking" }) { return "Reasoned through approach" }
        if events.contains(where: { $0.type == "stdout" || $0.type == "stderr" }) { return "Checked output" }
        if readCount > 0 || searchCount > 0 { return "Explored the codebase" }
        if commandCount > 0 { return "Ran project checks" }
        return "Explored and used tools"
    }

    private var summary: String {
        var parts: [String] = []
        if readCount > 0 { parts.append("\(readCount) file\(readCount == 1 ? "" : "s")") }
        if searchCount > 0 { parts.append("\(searchCount) search\(searchCount == 1 ? "" : "es")") }
        if commandCount > 0 { parts.append("\(commandCount) command\(commandCount == 1 ? "" : "s")") }
        if !parts.isEmpty { return parts.joined(separator: ", ") }

        let tools = events.filter { $0.kind == "tool_use" || $0.type == "action" }.count
        let outputs = events.filter { $0.kind == "tool_result" || $0.type == "stdout" || $0.type == "stderr" }.count
        if tools > 0 || outputs > 0 {
            return "\(tools) tool\(tools == 1 ? "" : "s"), \(outputs) result\(outputs == 1 ? "" : "s")"
        }
        return "\(events.count) step\(events.count == 1 ? "" : "s")"
    }

    private var icon: String {
        events.contains(where: { $0.type == "thinking" }) ? "brain" : "wrench.and.screwdriver.fill"
    }

    private var readCount: Int {
        events.filter { $0.toolName == "Read" }.count
    }

    private var searchCount: Int {
        events.filter { ["Grep", "Glob"].contains($0.toolName ?? "") }.count
    }

    private var commandCount: Int {
        events.filter { ($0.toolName == "Bash") || ($0.type == "action" && $0.tool == "shell") }.count
    }
}

private struct RunnerCard: View {
    let event: SessionEvent?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.textMuted)
                    Text("Runner details")
                        .font(LoupeFont.caption)
                        .foregroundStyle(Color.textMuted)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            if expanded, let text = event?.detailText {
                CodePreview(text: text)
            }
        }
    }
}

private struct ActivityRow: View {
    let event: SessionEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.actionTitle)
                        .font(LoupeFont.caption)
                        .foregroundStyle(Color.textPrimary)
                    if !event.detailText.isEmpty {
                        Text(event.detailText)
                            .font(event.type == "stdout" || event.type == "stderr" ? LoupeFont.code : LoupeFont.caption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        if event.type == "thinking" { return "brain" }
        if event.type == "stdout" || event.type == "stderr" || event.kind == "tool_result" { return event.isError == true || event.type == "stderr" ? "xmark.octagon.fill" : "checkmark.circle.fill" }
        if event.type == "action", event.tool == "shell" { return "terminal" }
        if event.kind == "tool_use" { return "wrench.and.screwdriver.fill" }
        return "circle.fill"
    }

    private var tint: Color {
        event.isError == true || event.type == "stderr" ? .riskAlert : .accent
    }
}

private struct SectionHeader: View {
    let system: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.accent)
            Text(title)
                .font(LoupeFont.bodyMedium)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text(subtitle)
                .font(LoupeFont.caption)
                .foregroundStyle(Color.textMuted)
        }
    }
}

private struct MiniInfoRow: View {
    let system: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(LoupeFont.caption)
                .foregroundStyle(Color.textMuted)
            Text(detail)
                .font(LoupeFont.code)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.chipFill))
    }
}

private struct CodePreview: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(LoupeFont.code)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: true, vertical: true)
                .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.textPrimary.opacity(0.04)))
    }
}

private extension String {
    var deletingLastPathComponentDisplay: String {
        let parent = (self as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? "" : parent
    }
}

#Preview("Session Journal") {
    NavigationStack {
        SessionView(
            store: SessionStore(
                snapshot: PreviewSessionData.snapshot,
                pairing: Pairing(host: URL(string: "http://127.0.0.1:4173")!, token: "preview")
            ),
            pairing: Pairing(host: URL(string: "http://127.0.0.1:4173")!, token: "preview")
        )
    }
}

private enum PreviewSessionData {
    static let snapshot: SessionSnapshot = {
        let json = """
        {
          "id": "preview-session",
          "harnessId": "claude-code",
          "message": "Add refresh icon to the inbox refresh button",
          "status": "completed",
          "events": [
            { "id": 1, "type": "claude", "kind": "message", "text": "I am checking where the toolbar button is rendered, then I will make the smallest UI change." },
            { "id": 2, "type": "claude", "kind": "tool_use", "toolName": "Read", "text": "Read: Sources/HomeView.swift" },
            { "id": 3, "type": "claude", "kind": "tool_use", "toolName": "Grep", "text": "Grep: refresh in Sources" },
            { "id": 4, "type": "claude", "kind": "file_change", "path": "Sources/HomeView.swift", "changeKind": "edit", "status": "modified", "additions": 2, "deletions": 1, "patch": "@@ preview @@\\n-Text(\\\"Refresh\\\")\\n+Image(systemName: \\\"arrow.clockwise\\\")\\n+Text(\\\"Refresh\\\")" },
            { "id": 5, "type": "claude", "kind": "tool_use", "toolName": "Bash", "text": "xcodebuild -scheme LoupeSwiftUI build" },
            { "id": 6, "type": "branch", "kind": "committed", "branch": "loupe/refresh-icon" },
            { "id": 7, "type": "handoff", "kind": "ready", "handoff": { "tldr": "Added the refresh icon while keeping the existing button layout stable.", "what_changed": ["Added the arrow.clockwise symbol beside Refresh.", "Kept existing spacing and typography."], "files_changed": ["Sources/HomeView.swift"], "tests_run": ["xcodebuild succeeded"], "tests_not_run": [], "assumptions": ["Using SF Symbols is acceptable here."], "risks": [], "confidence": 0.91 } },
            { "id": 8, "type": "done", "status": "completed" }
          ],
          "nextEventId": 9,
          "startedAt": "2026-05-31T10:00:00Z",
          "exitCode": 0,
          "dispatch": {
            "ticket": {
              "repo": "sixi3/loupe",
              "number": 102,
              "title": "Add refresh icon to the inbox refresh button",
              "url": "https://github.com/sixi3/loupe/issues/102",
              "kind": "issue"
            },
            "mode": "branch"
          },
          "branch": { "name": "loupe/refresh-icon", "base": "main", "repo": "sixi3/loupe" }
        }
        """
        return try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    }()
}
