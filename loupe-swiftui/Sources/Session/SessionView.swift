import SwiftUI

// MARK: - SessionView
// Live agent run: dispatch status, streaming transcript, branch/PR surface.
struct SessionView: View {
    @State var store: SessionStore
    let pairing: Pairing
    @State private var reviewRef: SessionStore.PRRef?
    @State private var blocks: [TranscriptBlock] = []
    @State private var openFacet: HandoffFacet?

    /// Condensed "receipt" derived from the finished run — drives the bento dock.
    private var summary: HandoffSummary { HandoffSummary(store: store) }

    /// Show the sticky handoff dock once the run settles with a real handoff.
    private var showDock: Bool {
        if case .completed = store.phase { return summary.isPresent }
        return false
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
        HStack(spacing: 10) {
            Text(store.item.title)
                .font(LoupeFont.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            AgentGlyph(agent: store.harness, size: 24)
        }
        .frame(maxWidth: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    TimelineItem(icon: "paperplane", tint: .accent, showsConnector: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Ticket dispatched to \(store.harness.label)")
                                .font(LoupeFont.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                            CompactSessionTicket(item: store.item)
                        }
                    }
                        .id("task")

                    ForEach(blocks) { block in
                        TranscriptBlockView(
                            block: block,
                            agent: store.harness,
                            isLatest: block.id == blocks.last?.id,
                            sessionRunning: store.isRunning,
                            canReview: store.prRef != nil,
                            onReview: {
                                if let ref = store.prRef { reviewRef = ref }
                            }
                        )
                        .id(block.id)
                    }
                }
                .padding(.top, LoupeSpace.xl)
                .padding(.horizontal, LoupeSpace.xl)
                .padding(.bottom, LoupeSpace.xxl)
            }
            .onAppear {
                blocks = TranscriptBlock.build(from: store.events)
            }
            .onChange(of: store.events.count) {
                let updatedBlocks = TranscriptBlock.build(from: store.events)
                blocks = updatedBlocks
                if let last = updatedBlocks.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
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
