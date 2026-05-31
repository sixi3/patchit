import Foundation
import Observation

// MARK: - SessionStore
// Dispatches a ticket, then streams the agent's events live over SSE.
@MainActor
@Observable
final class SessionStore {
    enum Phase: Equatable {
        case dispatching
        case streaming
        case completed(success: Bool)
        case failed(String)
    }

    let item: InboxItem
    let harness: Agent
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

    init(item: InboxItem, pairing: Pairing, harness: Agent? = nil, workspaceId: String? = nil) {
        self.item = item
        self.harness = harness ?? item.targetAgent
        self.pairing = pairing
        self.workspaceId = workspaceId
    }

    /// True once the agent pushed a branch we can open a PR from.
    var hasBranch: Bool { branch != nil }

    func start() async {
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

    private func listen(client: LoupeClient, sessionId: String) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            do {
                for try await event in client.events(sessionId: sessionId, since: 0) {
                    guard let self else { return }
                    self.events.append(event)
                    if event.type == "branch", event.kind == "pr_ready",
                       let number = event.prNumber, let repo = event.repo {
                        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
                        if parts.count == 2 {
                            self.prRef = PRRef(owner: parts[0], repo: parts[1], number: number)
                        }
                    }
                    if event.type == "done" {
                        self.phase = .completed(success: event.status == "completed")
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
}
