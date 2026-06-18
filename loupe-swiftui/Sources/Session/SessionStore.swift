import Foundation
import Observation

// MARK: - SessionStore
// Dispatches a ticket, then streams the agent's events live over SSE.
@MainActor
@Observable
final class SessionStore: Identifiable {
    enum Phase: Equatable {
        case dispatching
        case streaming
        case completed(success: Bool)
        case stopped
        case failed(String)
    }

    let id = UUID()
    let item: InboxItem
    let harness: Agent
    let startedAt: Date
    private let pairing: Pairing
    private let workspaceId: String?

    struct PRRef: Equatable, Identifiable {
        let owner: String
        let repo: String
        let number: Int
        var id: String { "\(owner)/\(repo)#\(number)" }
    }

    private(set) var phase: Phase = .dispatching
    private(set) var events: [SessionEvent] = []
    private(set) var sessionId: String?
    private(set) var branch: DispatchResponse.Branch?
    private(set) var prRef: PRRef?
    private(set) var metrics: SessionMetrics?

    private var streamTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var hasStarted = false
    private var lastError: String?

    init(item: InboxItem, pairing: Pairing, harness: Agent? = nil, workspaceId: String? = nil) {
        self.item = item
        self.harness = harness ?? item.targetAgent
        self.startedAt = Date()
        self.pairing = pairing
        self.workspaceId = workspaceId
    }

    init(snapshot: SessionSnapshot, pairing: Pairing) {
        self.item = InboxItem(snapshot: snapshot)
        self.harness = Agent(harnessId: snapshot.harnessId)
        self.startedAt = Self.date(from: snapshot.startedAt) ?? Date()
        self.pairing = pairing
        self.workspaceId = nil
        self.events = snapshot.events
        self.sessionId = snapshot.id
        self.branch = snapshot.branch
        self.metrics = snapshot.metrics
        self.prRef = Self.prRef(from: snapshot.events)
        self.phase = Self.phase(from: snapshot)
        self.hasStarted = true
        self.lastError = snapshot.events.last(where: { $0.type == "error" })?.text
    }

    func apply(snapshot: SessionSnapshot) {
        events = Self.mergedEvents(existing: events, incoming: snapshot.events)
        sessionId = snapshot.id
        branch = snapshot.branch ?? branch
        metrics = snapshot.metrics ?? metrics
        prRef = Self.prRef(from: events)
        phase = Self.phase(from: snapshot)
        lastError = events.last(where: { $0.type == "error" })?.text
        hasStarted = true
        if !isRunning {
            streamTask?.cancel()
            streamTask = nil
            reconcileTask?.cancel()
            reconcileTask = nil
        }
    }

    /// True once the agent pushed a branch we can open a PR from.
    var hasBranch: Bool { branch != nil }

    /// Live (still working) vs. settled (completed/failed) — drives the pill count.
    var isRunning: Bool { phase == .dispatching || phase == .streaming }

    /// Whether the source GitHub issue should be suppressed from the inbox.
    /// Running sessions leave the card while work is active; successful runs or
    /// PR-ready sessions stay hidden as fixed. Failed or inconclusive runs let
    /// the ticket return.
    var hidesSourceIssueInInbox: Bool {
        if isRunning || prRef != nil { return true }
        if case .completed(let success) = phase, success { return true }
        return false
    }

    var elapsedDuration: TimeInterval {
        if let durationMs = metrics?.durationMs {
            return max(0, durationMs / 1000)
        }
        if isRunning {
            return max(0, Date().timeIntervalSince(startedAt))
        }
        if let doneAt = events.last(where: { $0.type == "done" }).flatMap({ Self.date(from: $0.at) }) {
            return max(0, doneAt.timeIntervalSince(startedAt))
        }
        return max(0, Date().timeIntervalSince(startedAt))
    }

    var displayCostUsd: Double? {
        if let cost = metrics?.costUsd { return cost }
        if let resultCost = events.reversed().compactMap({ $0.totalCostUsd ?? $0.costUsd }).first {
            return resultCost
        }
        return nil
    }

    var displayCostLabel: String? {
        if let cost = displayCostUsd {
            return String(format: "$%.2f", cost)
        }
        return item.costStripLabel
    }

    /// Short status for the sessions list row.
    var statusLabel: String {
        if prRef != nil { return "PR ready" }
        switch phase {
        case .dispatching: return "Starting…"
        case .streaming:   return "Working…"
        case .completed(let ok): return ok ? "Completed" : "Finished with issues"
        case .stopped:     return "Stopped"
        case .failed:      return "Failed"
        }
    }

    enum StatusTone { case running, prReady, completed, failed }
    var statusTone: StatusTone {
        if prRef != nil { return .prReady }
        switch phase {
        case .dispatching, .streaming: return .running
        case .completed(let ok):       return ok ? .completed : .failed
        case .stopped:                 return .failed
        case .failed:                  return .failed
        }
    }

    func start() async {
        guard !hasStarted else { return }   // dispatch exactly once
        hasStarted = true
        phase = .dispatching
        let client = LoupeClient(pairing: pairing)
        do {
            let resp = try await client.dispatch(item.dispatchRequest(workspaceId: workspaceId, harness: harness))
            sessionId = resp.sessionId
            branch = resp.branch
            phase = .streaming
            if let sid = resp.sessionId {
                listen(client: client, sessionId: sid)
            }
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    func reconnectIfRunning() {
        guard isRunning, let sessionId else { return }
        listen(client: LoupeClient(pairing: pairing), sessionId: sessionId, since: events.map(\.id).max().map { $0 + 1 } ?? 0)
    }

    private func listen(client: LoupeClient, sessionId: String, since: Int = 0) {
        streamTask?.cancel()
        startReconciliation(client: client, sessionId: sessionId)
        streamTask = Task { [weak self] in
            var sawDone = false
            do {
                for try await event in client.events(sessionId: sessionId, since: since) {
                    guard let self else { return }
                    if self.events.contains(where: { $0.id == event.id }) { continue }
                    self.events.append(event)
                    if event.type == "error", let text = event.text, !text.isEmpty {
                        self.lastError = text
                    }
                    if event.type == "branch", event.kind == "pr_ready",
                       let number = event.prNumber, let repo = event.repo {
                        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
                        if parts.count == 2 {
                            self.prRef = PRRef(owner: parts[0], repo: parts[1], number: number)
                        }
                    }
                    if event.type == "done" {
                        sawDone = true
                        if event.status == "completed" {
                            self.phase = .completed(success: true)
                        } else if event.status == "stopped" {
                            self.phase = .stopped
                        } else {
                            self.phase = .failed(self.lastError ?? "The agent run did not complete.")
                        }
                        self.reconcileTask?.cancel()
                        self.reconcileTask = nil
                    }
                }
                guard !sawDone else { return }
                await self?.reconcileSnapshot(client: client, sessionId: sessionId)
            } catch {
                guard let self else { return }
                let reconciled = await self.reconcileSnapshot(client: client, sessionId: sessionId)
                if !reconciled {
                    self.phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
                    self.reconcileTask?.cancel()
                    self.reconcileTask = nil
                }
            }
        }
    }

    /// Tears down the local stream without touching the agent on the Mac.
    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        reconcileTask?.cancel()
        reconcileTask = nil
    }

    /// User-initiated stop. Asks the daemon to kill the harness process group, then
    /// optimistically settles to `.stopped` so the UI reacts instantly. The streamed
    /// "stopped" done event reconciles this if the agent was already mid-shutdown.
    func stop() async {
        guard isRunning, let sessionId else { return }
        phase = .stopped
        cancel()
        do {
            try await LoupeClient(pairing: pairing).stopSession(sessionId)
        } catch {
            // The kill request failed (e.g. transient network). Resume listening so
            // the real run state isn't misrepresented as stopped.
            phase = .streaming
            reconnectIfRunning()
        }
    }

    private func startReconciliation(client: LoupeClient, sessionId: String) {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.isRunning else { return }
                _ = await self.reconcileSnapshot(client: client, sessionId: sessionId)
            }
        }
    }

    @discardableResult
    private func reconcileSnapshot(client: LoupeClient, sessionId: String) async -> Bool {
        do {
            guard let snapshot = try await client.sessions().first(where: { $0.id == sessionId }) else {
                return false
            }
            apply(snapshot: snapshot)
            return true
        } catch {
            return false
        }
    }

    private static func prRef(from events: [SessionEvent]) -> PRRef? {
        guard let event = events.last(where: { $0.type == "branch" && $0.kind == "pr_ready" }),
              let number = event.prNumber,
              let repo = event.repo else { return nil }
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return PRRef(owner: parts[0], repo: parts[1], number: number)
    }

    private static func phase(from snapshot: SessionSnapshot) -> Phase {
        if snapshot.status == "running" { return .streaming }
        if let done = snapshot.events.last(where: { $0.type == "done" }) {
            switch done.status {
            case "completed": return .completed(success: true)
            case "stopped":   return .stopped
            default:
                return .failed(snapshot.events.last(where: { $0.type == "error" })?.text ?? "The agent run did not complete.")
            }
        }
        if snapshot.status == "stopped" { return .stopped }
        if snapshot.status == "completed" { return .completed(success: snapshot.exitCode == 0 || snapshot.exitCode == nil) }
        if snapshot.status == "failed" || snapshot.status == "interrupted" {
            return .failed(snapshot.events.last(where: { $0.type == "error" })?.text ?? "The agent run did not complete.")
        }
        return .completed(success: false)
    }

    private static func mergedEvents(existing: [SessionEvent], incoming: [SessionEvent]) -> [SessionEvent] {
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for event in incoming {
            byId[event.id] = event
        }
        return byId.values.sorted { $0.id < $1.id }
    }

    private static func date(from iso: String?) -> Date? {
        guard let iso else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }
}

private extension InboxItem {
    init(snapshot: SessionSnapshot) {
        let ticket = snapshot.dispatch?.ticket
        let repo = ticket?.repo ?? "unknown/repo"
        let number = ticket?.number ?? 0
        let title = ticket?.title ?? snapshot.message?.split(separator: "\n").first.map(String.init) ?? "Recovered session"
        let summary = snapshot.message?.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        self.init(
            id: repo == "unknown/repo" ? snapshot.id : "\(repo)#\(number)",
            source: .github,
            reference: number > 0 ? "GH-\(number)" : "Session",
            repo: "/\(repo)",
            title: title,
            priority: .normal,
            issueType: .task,
            updatedAt: "",
            blueprint: Blueprint(
                outcome: .ready,
                summary: summary?.isEmpty == false ? summary : "Recovered from the Mac daemon.",
                defaultAgent: Agent(harnessId: snapshot.harnessId),
                blueprintConfidence: nil
            ),
            number: number,
            issueURL: ticket?.url ?? ""
        )
    }
}
