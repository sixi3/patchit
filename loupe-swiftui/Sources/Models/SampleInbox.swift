import Foundation

// Demo inbox for the alpha homescreen. Mirrors node 210:18465.
// Replace with `/api/github/inbox` once the LoupeClient networking layer lands.

enum SampleInbox {
    static let items: [InboxItem] = [
        InboxItem(
            id: "GH-101",
            source: .github,
            reference: "GH-101",
            repo: "/lumenpay/payments-api",
            title: "Fix duplicate Stripe charges under concurrent webhook delivery",
            priority: .p0,
            issueType: .bug,
            updatedAt: "24m",
            blueprint: Blueprint(
                outcome: .ready,
                summary: "Replace SELECT-then-INSERT with an atomic INSERT … ON CONFLICT DO NOTHING on a UNIQUE(event_id) column.",
                size: "M",
                files: [
                    .init(path: "src/stripe.ts", isNew: false, confidence: 0.9, why: "Webhook handler entrypoint"),
                    .init(path: "src/processed_events.ts", isNew: false, confidence: 0.82, why: "Idempotency store"),
                    .init(path: "db/user_data_queries.sql", isNew: false, confidence: 0.74, why: "Add UNIQUE(event_id) index"),
                ],
                riskAreas: ["payments", "concurrency"],
                openQuestions: [],
                defaultAgent: .claude,
                blueprintConfidence: 0.74
            )
        ),
        InboxItem(
            id: "GH-102",
            source: .github,
            reference: "GH-102",
            repo: "/lumenpay/web-dashboard",
            title: "Add refresh icon to the inbox refresh button",
            priority: .normal,
            issueType: .task,
            updatedAt: "2h",
            blueprint: Blueprint(
                outcome: .ready,
                summary: "Add an inline SVG circular-arrow icon to the inbox refresh button, left of the text label.",
                size: "S",
                files: [
                    .init(path: "index.html", isNew: false, confidence: 0.95, why: "Button markup"),
                    .init(path: "styles.css", isNew: false, confidence: 0.88, why: "Icon spacing"),
                    .init(path: "icons/refresh.svg", isNew: true, confidence: 0.7, why: "New icon asset"),
                ],
                riskAreas: [],
                openQuestions: [],
                defaultAgent: .codex,
                blueprintConfidence: 0.92
            )
        ),
        InboxItem(
            id: "GH-103",
            source: .github,
            reference: "GH-103",
            repo: "/lumenpay/web-dashboard",
            title: "Persist column sort order across dashboard reloads",
            priority: .low,
            issueType: .feature,
            updatedAt: "3h",
            blueprint: Blueprint(
                outcome: .ready,
                summary: "Store the active sort key + direction in localStorage and rehydrate on table mount.",
                size: "S",
                files: [
                    .init(path: "src/components/Table.tsx", isNew: false, confidence: 0.86, why: "Sort state owner"),
                    .init(path: "src/hooks/usePersistedSort.ts", isNew: true, confidence: 0.72, why: "New persistence hook"),
                ],
                riskAreas: [],
                openQuestions: [],
                defaultAgent: .codex,
                blueprintConfidence: 0.84
            )
        ),
        InboxItem(
            id: "PAY-217",
            source: .jira,
            reference: "PAY-217",
            repo: "/lumenpay/payments-api",
            title: "Expose failed payment retry reason in admin timeline",
            priority: .p1,
            issueType: .story,
            updatedAt: "1h",
            blueprint: Blueprint(
                outcome: .needsInfo,
                summary: "Surface the processor retry reason beside failed payment events so support can distinguish bank declines from transient gateway failures.",
                size: "M",
                files: [
                    .init(path: "src/payments/timeline.tsx", isNew: false, confidence: 0.78, why: "Timeline renderer"),
                    .init(path: "src/payments/retryReason.ts", isNew: true, confidence: 0.6, why: "Reason mapping"),
                ],
                riskAreas: ["payments"],
                openQuestions: ["Which retry reason labels are customer-safe?"],
                missingInfo: [
                    "Sample failed-payment payloads for each processor",
                    "Final support-facing copy",
                ],
                defaultAgent: .claude,
                blueprintConfidence: 0.58
            )
        ),
        InboxItem(
            id: "GH-118",
            source: .github,
            reference: "GH-118",
            repo: "/lumenpay/payments-api",
            title: "Rate-limit the public webhook endpoint",
            priority: .p1,
            issueType: .chore,
            updatedAt: "5h",
            blueprint: Blueprint(
                outcome: .ready,
                summary: "Add a token-bucket limiter keyed by source IP in front of the webhook route.",
                size: "M",
                files: [
                    .init(path: "src/middleware/rateLimit.ts", isNew: true, confidence: 0.8, why: "New limiter"),
                    .init(path: "src/server.ts", isNew: false, confidence: 0.76, why: "Wire middleware"),
                ],
                riskAreas: ["infra", "security"],
                openQuestions: [],
                defaultAgent: .codex,
                blueprintConfidence: 0.81
            )
        ),
    ]
}
