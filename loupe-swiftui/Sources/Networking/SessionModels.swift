import Foundation

// MARK: - Dispatch + session wire models (from daemon.js)

extension Agent {
    /// Daemon harness id. Claude maps to "claude-code".
    var harnessId: String { self == .claude ? "claude-code" : "codex" }

    init(harnessId: String?) {
        self = harnessId == "claude-code" || harnessId == "claude" ? .claude : .codex
    }
}

/// POST /api/sessions/start request body.
struct DispatchRequest: Encodable {
    let message: String
    let workspaceId: String?
    let harness: String
    let dispatch: DispatchPayload?

    struct DispatchPayload: Encodable {
        let ticket: Ticket
        let mode: String   // "branch" | "plain"
        struct Ticket: Encodable {
            let repo: String     // "owner/repo"
            let number: Int
            let title: String
            let url: String
            let kind: String     // "issue" | "review"
        }
    }
}

/// POST /api/sessions/start response (bare JSON, not enveloped).
struct DispatchResponse: Decodable {
    let ok: Bool
    let sessionId: String?
    let status: String?
    let harness: String?
    let branch: Branch?
    let error: String?

    struct Branch: Decodable {
        let name: String
        let base: String
        let repo: String
    }
}

/// GET /api/sessions response item from daemon serializeSession().
struct SessionSnapshot: Decodable, Identifiable {
    let id: String
    let harnessId: String?
    let message: String?
    let status: String?
    let events: [SessionEvent]
    let nextEventId: Int?
    let startedAt: String?
    let exitCode: Int?
    let dispatch: SnapshotDispatch?
    let branch: DispatchResponse.Branch?

    struct SnapshotDispatch: Decodable {
        let ticket: Ticket?
        let mode: String?

        struct Ticket: Decodable {
            let repo: String?
            let number: Int?
            let title: String?
            let url: String?
            let kind: String?
        }
    }
}

/// One SSE event: { id, at, type, ... }. Decoded loosely so unknown event
/// shapes still render (text + type), while known fields surface for UI.
struct SessionEvent: Decodable, Identifiable {
    let id: Int
    let at: String?
    let type: String
    let text: String?
    let status: String?
    let kind: String?
    let branch: String?
    let sha: String?
    let url: String?
    let repo: String?         // "owner/repo" on pr_ready
    let prNumber: Int?
    let prUrl: String?
    let compareUrl: String?

    /// Human-facing line for the transcript.
    var displayText: String {
        if let text, !text.isEmpty { return text }
        switch type {
        case "handoff":            return "Handoff ready."
        case "deviations_computed": return "Blueprint vs. result compared."
        case "done":               return status.map { "Session \($0)." } ?? "Done."
        default:                    return type
        }
    }
}
