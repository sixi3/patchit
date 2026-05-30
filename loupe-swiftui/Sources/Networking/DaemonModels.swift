import Foundation

// MARK: - Daemon payloads (exact shapes from daemon.js)

/// GET /api/v1/inbox → data
struct InboxPayload: Decodable {
    let fetchedAt: String
    let viewer: Viewer
    let assigned: [DaemonTicket]
    let reviews: [DaemonTicket]

    struct Viewer: Decodable {
        let login: String?
        let avatarUrl: String?
    }
}

/// A normalized ticket from fetchGithubInbox().
struct DaemonTicket: Decodable, Identifiable {
    let kind: String          // "issue" | "review"
    let id: Int
    let number: Int
    let title: String
    let body: String
    let url: String
    let state: String
    let isPr: Bool
    let labels: [String]
    let repo: String          // "owner/repo"
    let updatedAt: String
    let author: String?
    let blueprint: Blueprint? // schema-aligned; nil if not yet generated
}

/// GET /api/health → (subset we use)
struct HealthPayload: Decodable {
    let ok: Bool
    let cwd: String?
    let defaultHarness: String?
    let workspaces: [Workspace]?

    struct Workspace: Decodable {
        let id: String?
        let name: String?
        let path: String?
    }
}
