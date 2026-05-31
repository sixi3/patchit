import Foundation

// MARK: - LoupeClient
// Talks to the Mac daemon. Token goes in the X-Loupe-Token header (matches the
// daemon's isAuthorized()). All /api/v1 calls decode the { ok, data, error } envelope.
actor LoupeClient {
    private let pairing: Pairing
    private let session: URLSession

    // Nonisolated immutables so the SSE stream can read them off-actor.
    nonisolated let host: URL
    nonisolated let token: String
    nonisolated let streamSession: URLSession

    init(pairing: Pairing) {
        self.pairing = pairing
        self.host = pairing.host
        self.token = pairing.token
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)

        let stream = URLSessionConfiguration.default
        stream.timeoutIntervalForRequest = .infinity
        stream.timeoutIntervalForResource = .infinity
        self.streamSession = URLSession(configuration: stream)
    }

    // MARK: Endpoints
    func health() async throws -> HealthPayload {
        try await getRaw(path: "/api/health", as: HealthPayload.self)
    }

    func inbox() async throws -> InboxPayload {
        try await getEnvelope(path: "/api/v1/inbox", as: InboxPayload.self)
    }

    /// POST /api/sessions/start — returns bare JSON with sessionId.
    func dispatch(_ body: DispatchRequest) async throws -> DispatchResponse {
        let data = try JSONEncoder().encode(body)
        let resp = try await request(path: "/api/sessions/start", method: "POST", body: data, as: DispatchResponse.self)
        if !resp.ok { throw LoupeError.api(.init(code: "DISPATCH_FAILED", message: resp.error ?? "Dispatch failed.", retryable: true)) }
        return resp
    }

    // MARK: PR review
    func prDetail(owner: String, repo: String, number: Int) async throws -> PRDetail {
        try await getEnvelope(path: "/api/v1/prs/\(owner)/\(repo)/\(number)", as: PRDetail.self)
    }

    func mergePR(owner: String, repo: String, number: Int) async throws -> MergeResult {
        let body = try JSONSerialization.data(withJSONObject: [:])
        return try await postEnvelope(path: "/api/v1/prs/\(owner)/\(repo)/\(number)/merge", body: body, as: MergeResult.self)
    }

    func reviewPR(owner: String, repo: String, number: Int, approve: Bool, comment: String?) async throws {
        let payload: [String: Any] = [
            "event": approve ? "APPROVE" : "REQUEST_CHANGES",
            "body": comment ?? "",
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await postEnvelope(path: "/api/v1/prs/\(owner)/\(repo)/\(number)/review", body: body, as: EmptyData.self)
    }

    func rejectPR(owner: String, repo: String, number: Int, reason: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["reason": reason])
        _ = try await postEnvelope(path: "/api/v1/prs/\(owner)/\(repo)/\(number)/reject", body: body, as: EmptyData.self)
    }

    private func postEnvelope<T: Decodable>(path: String, body: Data, as type: T.Type) async throws -> T {
        let env = try await request(path: path, method: "POST", body: body, as: APIEnvelope<T>.self)
        if let e = env.error { throw LoupeError.api(e) }
        guard env.ok, let data = env.data else {
            throw LoupeError.api(.init(code: "EMPTY", message: "Empty response.", retryable: true))
        }
        return data
    }

    /// SSE stream of session events. Yields each event as it arrives.
    nonisolated func events(sessionId: String, since: Int = 0) -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "/api/sessions/events/\(sessionId)?since=\(since)", relativeTo: host) else {
                        throw LoupeError.badURL
                    }
                    var req = URLRequest(url: url)
                    req.setValue(token, forHTTPHeaderField: "X-Loupe-Token")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = .infinity

                    let (bytes, response) = try await streamSession.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw LoupeError.http(http.statusCode)
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !json.isEmpty, let data = json.data(using: .utf8) else { continue }
                        if let event = try? decoder.decode(SessionEvent.self, from: data) {
                            continuation.yield(event)
                            if event.type == "done" { continuation.finish(); return }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Stale refresh
    /// Force-regenerate a stale blueprint for one issue (daemon re-fetches it).
    func refreshBlueprint(owner: String, repo: String, number: Int) async throws {
        let empty = try JSONSerialization.data(withJSONObject: [:])
        _ = try await postEnvelope(path: "/api/v1/blueprints/\(owner)/\(repo)/\(number)/refresh",
                                   body: empty, as: EmptyData.self)
    }

    // MARK: GitHub Device Flow (alpha connect)
    func githubDeviceStart() async throws -> GitHubDeviceStart {
        let empty = try JSONSerialization.data(withJSONObject: [:])
        return try await request(path: "/api/github/oauth/start", method: "POST", body: empty, as: GitHubDeviceStart.self)
    }

    func githubDevicePoll(flowId: String) async throws -> GitHubDevicePoll {
        let body = try JSONSerialization.data(withJSONObject: ["flowId": flowId])
        return try await request(path: "/api/github/oauth/poll", method: "POST", body: body, as: GitHubDevicePoll.self)
    }

    // MARK: Core
    /// For envelope endpoints: { ok, data, error }.
    private func getEnvelope<T: Decodable>(path: String, as type: T.Type) async throws -> T {
        let env = try await request(path: path, method: "GET", as: APIEnvelope<T>.self)
        if let e = env.error { throw LoupeError.api(e) }
        guard env.ok, let data = env.data else {
            throw LoupeError.api(.init(code: "EMPTY", message: "Empty response.", retryable: true))
        }
        return data
    }

    /// For bare-JSON endpoints like /api/health.
    private func getRaw<T: Decodable>(path: String, as type: T.Type) async throws -> T {
        try await request(path: path, method: "GET", as: T.self)
    }

    private func request<T: Decodable>(path: String, method: String, body: Data? = nil, as type: T.Type) async throws -> T {
        guard let url = URL(string: path, relativeTo: pairing.host) else { throw LoupeError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(pairing.token, forHTTPHeaderField: "X-Loupe-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw LoupeError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Try to surface the daemon's structured error.
            if let env = try? JSONDecoder().decode(APIEnvelope<EmptyData>.self, from: data), let e = env.error {
                throw LoupeError.api(e)
            }
            if let bare = try? JSONDecoder().decode(BareErrorResponse.self, from: data),
               let message = bare.message {
                throw LoupeError.api(.init(code: "HTTP_\(http.statusCode)", message: message, retryable: false))
            }
            throw LoupeError.http(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LoupeError.decoding(String(describing: error))
        }
    }

    private struct EmptyData: Decodable {}

    private struct BareErrorResponse: Decodable {
        let error: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case error, message
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let decodedError = try? c.decode(String.self, forKey: .error)
            let decodedMessage = try? c.decode(String.self, forKey: .message)
            self.error = decodedError
            self.message = decodedMessage ?? decodedError
        }
    }
}
