import Foundation

// MARK: - Daemon contract models
//
// `Blueprint` mirrors blueprint.schema.json EXACTLY so the UI can never drift
// from what the daemon produces. `InboxItem` wraps a blueprint with the issue
// metadata the inbox needs (source, repo, priority, type, freshness).
//
// Display strings (e.g. "24m", ring 0–100) are DERIVED here, not stored, so the
// schema contract stays clean.

// MARK: Agent
enum Agent: String, Codable, CaseIterable {
    case claude
    case codex

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }
}

// MARK: Ticket source / type
enum TicketSource: String, Codable {
    case github
    case jira

    var label: String { self == .github ? "GitHub" : "Jira" }
}

enum IssueType: String, Codable {
    case bug, task, story, feature, chore

    /// SF Symbol fallback; swap for the colored Phosphor/Jira glyph set later.
    var sfSymbol: String {
        switch self {
        case .bug:     return "ladybug.fill"
        case .task:    return "checkmark.square.fill"
        case .story:   return "bookmark.fill"
        case .feature: return "sparkles"
        case .chore:   return "wrench.fill"
        }
    }
}

// MARK: Blueprint (schema-aligned)
struct BlueprintFile: Codable, Identifiable, Hashable {
    let path: String
    let isNew: Bool
    let confidence: Double
    let why: String

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, why
        case isNew = "is_new"
        case confidence
    }
}

struct Blueprint: Codable {
    enum Outcome: String, Codable {
        case ready
        case needsInfo = "needs_info"
    }

    let outcome: Outcome
    let summary: String?
    let size: String?                 // S | M | L | XL
    let files: [BlueprintFile]
    let riskAreas: [String]
    let openQuestions: [String]
    let missingInfo: [String]
    let defaultAgent: Agent?
    let blueprintConfidence: Double?  // 0–1

    enum CodingKeys: String, CodingKey {
        case outcome, summary, size, files
        case riskAreas = "risk_areas"
        case openQuestions = "open_questions"
        case missingInfo = "missing_info"
        case defaultAgent = "default_agent"
        case blueprintConfidence = "blueprint_confidence"
    }

    // Defaults so partial daemon payloads decode cleanly.
    init(
        outcome: Outcome,
        summary: String? = nil,
        size: String? = nil,
        files: [BlueprintFile] = [],
        riskAreas: [String] = [],
        openQuestions: [String] = [],
        missingInfo: [String] = [],
        defaultAgent: Agent? = nil,
        blueprintConfidence: Double? = nil
    ) {
        self.outcome = outcome
        self.summary = summary
        self.size = size
        self.files = files
        self.riskAreas = riskAreas
        self.openQuestions = openQuestions
        self.missingInfo = missingInfo
        self.defaultAgent = defaultAgent
        self.blueprintConfidence = blueprintConfidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        size = try c.decodeIfPresent(String.self, forKey: .size)
        files = try c.decodeIfPresent([BlueprintFile].self, forKey: .files) ?? []
        riskAreas = try c.decodeIfPresent([String].self, forKey: .riskAreas) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        missingInfo = try c.decodeIfPresent([String].self, forKey: .missingInfo) ?? []
        defaultAgent = try c.decodeIfPresent(Agent.self, forKey: .defaultAgent)
        blueprintConfidence = try c.decodeIfPresent(Double.self, forKey: .blueprintConfidence)
    }
}

// MARK: Inbox item (blueprint + issue metadata)
struct InboxItem: Identifiable {
    let id: String
    let source: TicketSource
    let reference: String       // "GH-101", "PAY-217"
    let repo: String            // "/lumenpay/payments-api"
    let title: String
    let priority: LoupePriority
    let issueType: IssueType
    let updatedAt: String       // pre-formatted freshness, e.g. "24m"
    let blueprint: Blueprint
    var number: Int = 0
    var issueURL: String = ""

    // Derived display helpers ------------------------------------------------
    var isReady: Bool { blueprint.outcome == .ready }

    /// Confidence as 0–100 for the ring. nil → 0.
    var confidence: Int { Int(((blueprint.blueprintConfidence ?? 0) * 100).rounded()) }

    var fileCount: Int { blueprint.files.count }
    var riskCount: Int { blueprint.riskAreas.count }
    var questionCount: Int { blueprint.openQuestions.count }

    /// Agent the dispatch button targets.
    var targetAgent: Agent { blueprint.defaultAgent ?? .codex }

    /// "owner/repo" with the display leading slash stripped.
    var repoFullName: String { String(repo.drop(while: { $0 == "/" })) }

    /// Payload for POST /api/sessions/start. Branch mode for GitHub issues.
    func dispatchRequest(workspaceId: String?) -> DispatchRequest {
        DispatchRequest(
            message: dispatchBrief,
            workspaceId: workspaceId,
            harness: targetAgent.harnessId,
            dispatch: .init(
                ticket: .init(repo: repoFullName, number: number, title: title,
                              url: issueURL, kind: source == .github ? "issue" : "issue"),
                mode: "branch"
            )
        )
    }

    /// The brief handed to the agent: title + summary + predicted files.
    private var dispatchBrief: String {
        var lines = ["\(reference): \(title)"]
        if let s = blueprint.summary { lines.append("\n\(s)") }
        if !blueprint.files.isEmpty {
            lines.append("\nLikely files:")
            lines.append(contentsOf: blueprint.files.map { "- \($0.path)" })
        }
        return lines.joined(separator: "\n")
    }
}
