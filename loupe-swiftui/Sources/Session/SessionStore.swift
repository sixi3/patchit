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

    private var streamTask: Task<Void, Never>?
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
        self.prRef = Self.prRef(from: snapshot.events)
        self.phase = Self.phase(from: snapshot)
        self.hasStarted = true
        self.lastError = snapshot.events.last(where: { $0.type == "error" })?.text
    }

    /// True once the agent pushed a branch we can open a PR from.
    var hasBranch: Bool { branch != nil }

    /// Live (still working) vs. settled (completed/failed) — drives the pill count.
    var isRunning: Bool { phase == .dispatching || phase == .streaming }

    /// Short status for the sessions list row.
    var statusLabel: String {
        if prRef != nil { return "PR ready" }
        switch phase {
        case .dispatching: return "Starting…"
        case .streaming:   return "Working…"
        case .completed(let ok): return ok ? "Completed" : "Finished with issues"
        case .failed:      return "Failed"
        }
    }

    enum StatusTone { case running, prReady, completed, failed }
    var statusTone: StatusTone {
        if prRef != nil { return .prReady }
        switch phase {
        case .dispatching, .streaming: return .running
        case .completed(let ok):       return ok ? .completed : .failed
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
        streamTask = Task { [weak self] in
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
                        if event.status == "completed" {
                            self.phase = .completed(success: true)
                        } else {
                            self.phase = .failed(self.lastError ?? "The agent run did not complete.")
                        }
                    }
                }
            } catch {
                self?.phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
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
            return done.status == "completed"
                ? .completed(success: true)
                : .failed(snapshot.events.last(where: { $0.type == "error" })?.text ?? "The agent run did not complete.")
        }
        if snapshot.status == "completed" { return .completed(success: snapshot.exitCode == 0 || snapshot.exitCode == nil) }
        if snapshot.status == "failed" || snapshot.status == "interrupted" {
            return .failed(snapshot.events.last(where: { $0.type == "error" })?.text ?? "The agent run did not complete.")
        }
        return .completed(success: false)
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
