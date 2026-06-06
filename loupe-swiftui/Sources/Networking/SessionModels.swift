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

    enum CodingKeys: String, CodingKey {
        case id, harnessId, message, status, events, nextEventId, startedAt, exitCode, dispatch, branch
    }

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

    private struct SnapshotBranch: Decodable {
        let name: String?
        let base: String?
        let repo: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        harnessId = try c.decodeIfPresent(String.self, forKey: .harnessId)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        events = try c.decodeIfPresent([SessionEvent].self, forKey: .events) ?? []
        nextEventId = try c.decodeIfPresent(Int.self, forKey: .nextEventId)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        dispatch = try c.decodeIfPresent(SnapshotDispatch.self, forKey: .dispatch)
        if let rawBranch = try c.decodeIfPresent(SnapshotBranch.self, forKey: .branch),
           let name = rawBranch.name {
            branch = .init(name: name, base: rawBranch.base ?? "", repo: rawBranch.repo ?? dispatch?.ticket?.repo ?? "")
        } else {
            branch = nil
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
    let tool: String?
    let toolName: String?
    let path: String?
    let input: String?
    let output: String?
    let changeKind: String?
    let isError: Bool?
    let additions: Int?
    let deletions: Int?
    let patch: String?
    let handoff: Handoff?

    struct Handoff: Decodable {
        let tldr: String?
        let whatChanged: [String]?
        let filesChanged: [String]?
        let testsRun: [String]?
        let testsNotRun: [String]?
        let assumptions: [String]?
        let risks: [String]?
        let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case tldr
            case whatChanged = "what_changed"
            case filesChanged = "files_changed"
            case testsRun = "tests_run"
            case testsNotRun = "tests_not_run"
            case assumptions
            case risks
            case confidence
        }
    }

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
