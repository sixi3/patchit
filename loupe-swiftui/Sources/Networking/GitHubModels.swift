import Foundation

// MARK: - GitHub Device Flow wire models (from daemon.js /api/github/oauth/*)
// Alpha uses Device Flow (no stable callback URL needed). The redirect flow
// arrives with the relay in beta.

/// POST /api/github/oauth/start
struct GitHubDeviceStart: Decodable {
    let ok: Bool
    let flowId: String?
    let userCode: String?
    let verificationUri: String?
    let expiresIn: Int?
    let interval: Int?
    let error: String?
}

/// POST /api/github/oauth/poll
struct GitHubDevicePoll: Decodable {
    let ok: Bool
    let status: String?   // "authorized" | "pending" | "waiting" | "expired" | <error code>
    let login: String?
    let interval: Int?
    let error: String?
}
