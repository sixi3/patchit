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

struct BlueprintCostEstimate: Codable, Hashable {
    struct BlueprintCost: Codable, Hashable {
        let actualUsd: Double?
        let currency: String?
        let measured: Bool?
        let provider: String?
        let model: String?
    }

    struct RangeCost: Codable, Hashable {
        let lowUsd: Double?
        let highUsd: Double?
        let currency: String?
        let basis: String?
        let includesEstimatedBlueprint: Bool?
    }

    let blueprint: BlueprintCost?
    let execution: RangeCost?
    let total: RangeCost?
}

struct Blueprint: Codable {
    enum Outcome: String, Codable {
        case ready
        case needsInfo = "needs_info"
    }

    let outcome: Outcome
    let status: String?
    let summary: String?
    let size: String?                 // S | M | L | XL
    let files: [BlueprintFile]
    let riskAreas: [String]
    let openQuestions: [String]
    let missingInfo: [String]
    let defaultAgent: Agent?
    let blueprintConfidence: Double?  // 0–1
    let costEstimate: BlueprintCostEstimate?
    let degraded: Bool                // real planner failed → heuristic fallback

    enum CodingKeys: String, CodingKey {
        case outcome, status, summary, size, files, degraded
        case riskAreas = "risk_areas"
        case openQuestions = "open_questions"
        case missingInfo = "missing_info"
        case defaultAgent = "default_agent"
        case blueprintConfidence = "blueprint_confidence"
        case costEstimate = "cost_estimate"
    }

    enum CamelCodingKeys: String, CodingKey {
        case riskAreas, openQuestions, missingInfo, defaultAgent, blueprintConfidence, costEstimate
    }

    // Defaults so partial daemon payloads decode cleanly.
    init(
        outcome: Outcome,
        status: String? = nil,
        summary: String? = nil,
        size: String? = nil,
        files: [BlueprintFile] = [],
        riskAreas: [String] = [],
        openQuestions: [String] = [],
        missingInfo: [String] = [],
        defaultAgent: Agent? = nil,
        blueprintConfidence: Double? = nil,
        costEstimate: BlueprintCostEstimate? = nil,
        degraded: Bool = false
    ) {
        self.outcome = outcome
        self.status = status
        self.summary = summary
        self.size = size
        self.files = files
        self.riskAreas = riskAreas
        self.openQuestions = openQuestions
        self.missingInfo = missingInfo
        self.defaultAgent = defaultAgent
        self.blueprintConfidence = blueprintConfidence
        self.costEstimate = costEstimate
        self.degraded = degraded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let camel = try decoder.container(keyedBy: CamelCodingKeys.self)
        outcome = try c.decodeIfPresent(Outcome.self, forKey: .outcome) ?? .needsInfo
        status = try c.decodeIfPresent(String.self, forKey: .status)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        size = try c.decodeIfPresent(String.self, forKey: .size)
        files = try c.decodeIfPresent([BlueprintFile].self, forKey: .files) ?? []
        riskAreas = try c.decodeIfPresent([String].self, forKey: .riskAreas)
            ?? camel.decodeIfPresent([String].self, forKey: .riskAreas)
            ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions)
            ?? camel.decodeIfPresent([String].self, forKey: .openQuestions)
            ?? []
        missingInfo = try c.decodeIfPresent([String].self, forKey: .missingInfo)
            ?? camel.decodeIfPresent([String].self, forKey: .missingInfo)
            ?? []
        defaultAgent = try c.decodeIfPresent(Agent.self, forKey: .defaultAgent)
            ?? camel.decodeIfPresent(Agent.self, forKey: .defaultAgent)
        blueprintConfidence = try c.decodeIfPresent(Double.self, forKey: .blueprintConfidence)
            ?? camel.decodeIfPresent(Double.self, forKey: .blueprintConfidence)
        costEstimate = try c.decodeIfPresent(BlueprintCostEstimate.self, forKey: .costEstimate)
            ?? camel.decodeIfPresent(BlueprintCostEstimate.self, forKey: .costEstimate)
        degraded = try c.decodeIfPresent(Bool.self, forKey: .degraded) ?? false
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
    var isAnalyzing: Bool { blueprint.status == "queued" || blueprint.status == "running" }

    /// True when the real planner failed and we fell back to ticket-text heuristics.
    /// The card should signal low trust rather than show a confident plan.
    var isDegraded: Bool { blueprint.degraded && !isAnalyzing }

    /// Agent the dispatch button targets.
    var targetAgent: Agent { blueprint.defaultAgent ?? .codex }

    var costLabel: String? {
        if let total = blueprint.costEstimate?.total,
           let low = total.lowUsd,
           let high = total.highUsd {
            if abs(low - high) < 0.005 {
                return String(format: "$%.2f", low)
            }
            return String(format: "$%.2f–%.2f", low, high)
        }
        if let actual = blueprint.costEstimate?.blueprint?.actualUsd {
            return String(format: "$%.2f", actual)
        }
        return nil
    }

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
