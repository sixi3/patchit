import Foundation

// MARK: - DaemonTicket → InboxItem
// Bridges the wire model to the view model: infers priority/type from GitHub
// labels, formats freshness, and reference. Best-effort and conservative.
extension DaemonTicket {
    func toInboxItem() -> InboxItem {
        InboxItem(
            id: "\(repo)#\(number)",
            source: .github,
            reference: "GH-\(number)",
            repo: "/" + repo,                       // "owner/repo" → "/owner/repo"
            title: title,
            priority: Self.priority(from: labels),
            issueType: Self.issueType(from: labels, isPr: isPr),
            updatedAt: Self.relativeTime(updatedAt),
            blueprint: blueprint ?? Blueprint(outcome: .needsInfo,
                                              summary: String(body.prefix(160)),
                                              missingInfo: ["Blueprint not generated yet"]),
            number: number,
            issueURL: url
        )
    }

    // MARK: Priority inference
    static func priority(from labels: [String]) -> LoupePriority {
        let l = labels.map { $0.lowercased() }
        func has(_ needles: [String]) -> Bool { l.contains { lab in needles.contains { lab.contains($0) } } }
        if has(["p0", "urgent", "critical", "blocker", "sev1", "priority: highest"]) { return .p0 }
        if has(["p1", "high", "important", "priority: high"]) { return .p1 }
        if has(["p3", "p4", "low", "minor", "trivial", "priority: low"]) { return .low }
        return .normal
    }

    // MARK: Type inference
    static func issueType(from labels: [String], isPr: Bool) -> IssueType {
        let l = labels.map { $0.lowercased() }
        func has(_ needles: [String]) -> Bool { l.contains { lab in needles.contains { lab.contains($0) } } }
        if has(["bug", "defect", "regression"]) { return .bug }
        if has(["feature", "enhancement"]) { return .feature }
        if has(["story", "user story"]) { return .story }
        if has(["chore", "maintenance", "infra", "refactor", "ci"]) { return .chore }
        return .task
    }

    // MARK: Relative time ("24m", "2h", "3d")
    static func relativeTime(_ iso: String) -> String {
        let fmt = ISO8601DateFormatter()
        guard let date = fmt.date(from: iso) else { return "" }
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }
}
