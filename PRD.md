# Loupe — Product Requirements Document

**Tagline:** *The smarter way to do smart work.*
**Subtitle:** See what your agent will change, before it changes anything.
**Version:** 0.2 (alpha — adds Blueprint)
**Status:** Mac daemon + iOS PWA shipping; Contract, Triage, and Blueprint designed; foundational hardening in flight
**Owner:** sixi3
**Last revised:** 2026-05-26

---

## 1. Problem

Engineers now have AI coding agents that can write production code. They don't have a way to **manage** those agents from anywhere but their desk, and they don't have a way to **trust** them without reading every diff.

The state of the art is three bad options:

1. **Sit at the laptop and babysit Claude / Codex.** Wastes the agent's main advantage — that it can work asynchronously while you do something else.
2. **Use a phone terminal** (Happy, Tactic Remote). Lets you watch the agent stream output on your phone, but you still drive a free-form chat. No structure. No pre-flight check. No way to know if the output is mergeable without reading every line of the diff.
3. **Cloud agent surfaces** (Claude Code on the web, Codex cloud). Lose local environment access, don't integrate with the real ticket queue, don't run on your machine with your keys, don't help your trust problem.

The deeper failure across all three: **none of them constrain the agent's inputs, predict its outputs, or shape its handoff back to a human.** A vague ticket becomes a vague prompt becomes a confidently-wrong PR. The reviewer has no choice but to read the entire diff, because the agent gives no signal about what it was unsure of, and no preview of what it was about to do.

## 2. Solution in one sentence

Loupe is the **contract** between you, your tickets, and your coding agents — an iOS-and-Mac product that pulls assigned issues into a phone-native inbox, generates a **Blueprint** of the change before you dispatch, runs the agent in a fresh git branch under a structured **Brief**, and surfaces a reviewable **Handoff** as a pull request on your phone.

## 3. Target user

**Primary persona — "Mid-senior IC at a 10–200 person engineering org."**
- Uses GitHub Issues or Linear (v1 ships with GitHub only).
- Already pays for Claude Max or has API access (BYOK).
- Already uses Claude Code or Codex CLI locally.
- Has 5–20 tickets in queue at any time.
- Spends 1–3 hours/day on "engineering management of self" — picking what to work on, context-switching.
- Owns an iPhone (iOS-first; Android via PWA fallback only in v1).

**Secondary persona — "Tech lead reviewing junior or agent-authored PRs."**
- 30–60 min/day on PR review.
- Lacks bandwidth to read entire diffs; wants authors (human or agent) to surface uncertainty.
- Will pay for **Blueprint visibility into team members' dispatches** before they happen.

**Explicit non-targets for v1:** enterprises with on-prem requirements, Jira-only teams (deferred to v2), Android-first users (PWA only).

## 4. Competitive landscape and wedge

| Product | Lead surface | What they own |
|---|---|---|
| Happy ([happy.engineering](https://happy.engineering/)) | Phone terminal + voice | Chat polish, App Store presence, E2E encryption |
| Tactic Remote ([tacticremote.com](https://tacticremote.com/)) | Menu-bar Mac + iOS terminal control | Multi-harness monitor with mDNS auto-pairing |
| Claude Code on the web | Cloud sandboxed runs | Zero-setup, no local Mac |
| GitHub Copilot Workspace | PR-stage AI suggestions | GitHub-native, deep diff context |
| **Loupe** | **Inbox → Blueprint → Brief → Handoff** | **Workflow + the Contract** |

Loupe does not compete on terminal polish. Loupe competes on:

1. **Inbox-first information architecture** — tickets are the noun, not chat sessions.
2. **The Blueprint** — a pre-dispatch, codebase-aware preview of every change. *No competitor has this.*
3. **The Contract** — Brief (inbound) and Handoff (outbound) as structured, validated artifacts.
4. **Triage routing** — bad tickets get caught at the door.
5. **Send-back as a structured loop**, not a free-form chat continuation.

## 5. Goals and non-goals

### Goals (v1, 8–10 weeks)
- A single developer reviews assigned GitHub issues, sees a **Blueprint** of each one (files affected, dependencies, migrations, cost, risk), dispatches with confidence to a local Codex or Claude Code, and approves+merges the resulting PR — entirely from an iPhone, in under 60 seconds of active interaction.
- Garbage-quality tickets are caught at triage and blocked from dispatch with specific missing fields.
- Every PR ships with a structured **Handoff** pre-filled into the PR body and rendered phone-native in the PWA.
- BYOK end-to-end. No credentials proxied through any Loupe-operated server.

### Non-goals (v1)
- Team features (shared inbox, assignment routing, role-based dispatch gating).
- Linear / Jira ticket sources.
- Auto-routing tickets to harnesses by content.
- Voice control.
- Native Android client.
- Cloud agent execution fallback.
- Model providers beyond Anthropic and OpenAI.

## 6. Key user stories

### Story 1: Inbox → Blueprint → PR while waiting for coffee
1. Anand opens Loupe on his iPhone. 6 inbox items: 4 assigned issues, 2 PRs awaiting review.
2. One issue card shows: `gold · 3 files · M-sized · ~$0.40 · payments + concurrency`.
3. He taps it. Instead of a dispatch sheet, the **Blueprint screen** opens: the agent's predicted files, a yellow flag on a planned schema migration, an open question about Postgres vs MySQL.
4. He taps the open question → picks "Postgres." The Blueprint regenerates in 8s.
5. He taps **Dispatch**. The composer is invisible — the Brief is built from the Blueprint and goes straight to the agent.
6. Puts phone down, gets coffee.
7. 3 minutes later, push notification: "PR ready · loupe/patchit-42-a8c1f3."
8. He opens the app. Handoff shows TL;DR, two yellow `verify_these` flags, and a callout: "⚠️ Agent touched 1 file not in Blueprint."
9. He taps the green PR card → GitHub Mobile opens with the PR body pre-filled. He reviews the deviation, leaves a comment, merges.

### Story 2: The garbage ticket
1. Anand sees a red `needs-info` chip on DATA-71. The card has no Blueprint — only triage output.
2. He taps. Instead of dispatch, he gets a "this ticket isn't ready" screen with three missing fields.
3. "Comment on GitHub" deep-links to the issue with a pre-filled template. He posts, the ticket goes into `waiting on @reporter` state.

### Story 3: The Blueprint warned him
1. Anand taps a Silver-tier ticket. Blueprint shows files including `src/auth/session.ts`.
2. The repo's `.loupe/sacred.yaml` lists `src/auth/*` as forbidden. The Blueprint surfaces this as a red **🛑 out-of-scope warning**.
3. He realizes the ticket is mis-scoped — it should be split into "session expiry behavior" (touchable) and "auth path change" (not).
4. He doesn't dispatch. He goes back to GitHub, edits the ticket to clarify scope.
5. Inbox re-blueprints automatically; the warning is gone. He dispatches.

### Story 4: Agent asks mid-flight (Story 3 in v0.1)
1. Anand dispatches a ticket whose Blueprint included one open question he didn't resolve.
2. Agent hits the ambiguity, halts with `outcome: needs_clarification`.
3. Push notification: "Agent has a question."
4. He taps an option in the PWA. Agent resumes. PR lands 4 min later.

### Story 5: Send-back via structured flag (Story 4 in v0.1)
1. Handoff comes back with `verify_these[0]: "I assumed the user table has an email_verified column."`
2. He taps the flag → "Send back to confirm." Composer is *not* shown.
3. The system augments the Brief with the constraint, resumes the session via `claude --resume`. New commit lands.

## 7. Functional requirements

| ID | Requirement | Status |
|---|---|---|
| F1 | Mac daemon auto-detects installed Codex and Claude Code binaries | ✅ Built |
| F2 | PWA shows a harness picker; disables unavailable harnesses | ✅ Built |
| F3 | Daemon serves a workspace selector, supports creating folders from phone | ✅ Built |
| F4 | Daemon streams agent events over SSE in a normalized shape (Codex JSON, Claude stream-json) | ✅ Built |
| F5 | Daemon exposes a GitHub inbox endpoint backed by a BYOK PAT | ✅ Built |
| F6 | Phone shows two-section inbox (assigned, review-requested) with workspace binding chips | ✅ Built |
| F7 | Dispatch from inbox pre-fills the composer with ticket + URL + tail directive | ✅ Built |
| F8 | Dispatch auto-checks-out `loupe/<slug>` branch on bound workspaces with clean tree | ✅ Built |
| F9 | On successful agent exit, daemon commits + pushes + emits `pr_ready` with compare URL | ✅ Built |
| F10 | PWA shows PR-ready compare URL as a tappable card deep-linking to GitHub Mobile | ✅ Built |
| F11 | **Tier-1 Triage** classifies each new ticket into `{dispatch, plan-and-dispatch, plan-with-critique, needs-info}` with `missingInfo[]` | 🟡 Designed |
| F12 | `needs-info` tickets show red chip; dispatch disabled; missing fields linked to "comment on GitHub" | 🟡 Designed |
| F13 | **Tier-2 Blueprint** generates a structured pre-dispatch preview (files, deps, migrations, tests, risks, cost, confidence) for every non-garbage ticket | 🟡 Designed (§8.1) |
| F14 | Blueprint is cached by `(ticket_content_hash, repo_HEAD_sha)`; re-runs on ticket edit or significant repo move | 🟡 Designed |
| F15 | Inbox card displays Blueprint summary chips (file count, size, cost estimate, top risk) | 🟡 Designed |
| F16 | Tapping a ticket opens the Blueprint screen *before* the dispatch sheet. "Dispatch" and "Adjust scope" are the two CTAs | 🟡 Designed |
| F17 | **Brief** is assembled deterministically from ticket + triage + Blueprint at dispatch time; injected as system prompt for the harness | 🟡 Designed (§8.2) |
| F18 | **Handoff** conforms to schema (`tldr`, `what_i_did`, `decisions`, `verify_these`, `test_plan`, `confidence`, `cost`, `outcome`); daemon validates and re-prompts on miss (≤ 2 retries) | 🟡 Designed (§8.3) |
| F19 | Handoff is **compared against the Blueprint**; deviations (files touched not predicted, missing migrations, scope creep) are surfaced in the PWA review screen | 🟡 Designed |
| F20 | Handoff `verify_these` items render as tappable flags; tapping pre-fills a send-back, resumes session via `claude --resume` / `codex exec resume` | 🟡 Designed |
| F21 | Agent can return `outcome: needs_clarification` with `questions[]` and `partial_work`; PWA shows structured options | 🟡 Designed |
| F22 | Daemon authenticates all API calls via `X-Loupe-Token`; pairing via QR code | 🔴 Required pre-alpha |
| F23 | Sessions, triage results, Blueprints, and Handoffs persist to SQLite; survive restart | 🔴 Required pre-alpha |
| F24 | Web Push notifications for `pr_ready`, `needs_clarification`, `push_failed`, `blueprint_ready` | 🔴 Required pre-alpha |
| F25 | Each session record displays cost (tokens in/out, USD) sourced from Handoff + SSE events; aggregated daily/weekly in settings | 🟡 Partial |
| F26 | `.loupe/sacred.yaml` per repo defines forbidden paths and named precedents; Blueprint enforces forbidden, Brief injects precedents | 🟡 Designed |

## 8. The three artifacts

The product's vocabulary. Each artifact has the same JSON keys recurring across it (`files_to_touch`, `migrations`, `verify_these`, etc.) so the PWA renders all three with the same components and users learn the schema once.

### 8.1 The Blueprint (pre-dispatch)

Generated at inbox-fetch time by a Tier-2 LLM call with read-only repo access. The user-facing artifact that says *"here is what the agent will do, before it does it."*

```jsonc
{
  "blueprint_version": "1.0",
  "ticket_ref": "sixi3/patchit#42",
  "generated_at": "2026-05-26T18:14:00Z",
  "repo_sha_at_generation": "a20d793",
  "model_used": "claude-haiku-4.5",
  "cost_to_generate": { "tokens_in": 11820, "tokens_out": 740, "usd": 0.024 },

  "summary": "Add UNIQUE constraint + ON CONFLICT to eliminate the Stripe webhook race. ~3 files, ~50 LOC, includes a migration.",

  "files_to_touch": [
    { "path": "src/webhooks/stripe.ts", "confidence": 0.95, "estimated_lines": 12, "why": "Contains the race (lines 112-178)" },
    { "path": "src/db/processed_events.ts", "confidence": 0.92, "estimated_lines": 18, "why": "Marker writer; needs ON CONFLICT" },
    { "path": "migrations/<new>.sql", "confidence": 0.88, "estimated_lines": 8, "why": "Requires UNIQUE(event_id) column" }
  ],
  "new_dependencies": [],
  "migrations": [
    { "kind": "schema", "description": "ADD UNIQUE(event_id) to processed_events", "risk": "medium", "rollback": "DROP CONSTRAINT" }
  ],
  "tests": [
    { "path": "src/webhooks/stripe.concurrency.test.ts", "kind": "new", "why": "Required by AC" },
    { "path": "src/webhooks/stripe.test.ts", "kind": "update", "why": "Existing tests may overlap" }
  ],
  "risk_surface": ["payments", "concurrency", "database-schema"],
  "out_of_scope_flags": [
    { "file": "src/payments/charge.ts", "reason": "Caller — agent should not touch", "confidence": 0.80 }
  ],
  "estimated": {
    "diff_size": "M",
    "dispatch_cost_usd": { "low": 0.28, "high": 0.55 },
    "wall_seconds": { "low": 90, "high": 240 }
  },
  "blueprint_confidence": 0.85,
  "open_questions": [
    "Postgres or MySQL in prod? Migration syntax differs."
  ]
}
```

**Where it appears:**
- **Inbox card:** chips for file count, size, cost, top risk.
- **Ticket detail screen:** full Blueprint rendered with collapsible sections — Files / Dependencies / Migrations / Tests / Out-of-scope / Open questions — plus an estimated cost and a confidence bar.
- **Dispatch flow:** the Blueprint screen *is* the dispatch sheet. "Dispatch" and "Adjust scope" are the two CTAs. No free-form text composer for ticket-driven dispatches.

### 8.2 The Brief (dispatch-time, agent-facing)

Assembled deterministically from ticket + Tier-1 triage + Blueprint + workspace scan, the instant the user taps **Dispatch**. Injected as `--append-system-prompt-file` for Claude and prepended to the prompt body for Codex. Eight sections, each terminating a specific source of guesswork:

| Section | Decision it terminates | Sourced from |
|---|---|---|
| `goal` | "What does success mean?" | `acceptanceCriteria` → `summary` |
| `constraints` | "What rules can't I break?" | Tier-1 triage `constraints[]` |
| `out_of_scope` | "What am I forbidden to touch?" | `.loupe/sacred.yaml` + Blueprint `out_of_scope_flags` |
| `context_map` | "Which files matter?" | Blueprint `files_to_touch` |
| `precedents` | "How does this codebase do similar work?" | `.loupe/sacred.yaml` precedents + grep-and-rank |
| `verification_plan` | "How will I know I'm done?" | Blueprint `tests` + AC |
| `decision_inputs` | "What options should I pick between?" | Blueprint `open_questions` + user's answers |
| `handoff_requirements` | "What must I produce?" | Reference to §8.3 |

Stored at `.loupe/briefs/<task-id>.md` for replay/debugging.

### 8.3 The Handoff (post-dispatch, agent-produced)

JSON schema (`handoff-1.0.json`) enforced via Claude's `--json-schema` or Codex's prompt instructions. Sections:

- `tldr` — one sentence
- `what_i_did` — `[{file, change, lines, why}]`
- `decisions` — `[{question, chose, because, alternative_considered}]`
- `verify_these` — `[{concern, severity, where}]` (the agent's confessions)
- `test_plan` — `{ran[], did_not_run[]}` with commands, results, durations
- `out_of_scope_observations` — things noticed but not fixed
- `confidence` — `{overall: 0..1, low_confidence_areas[]}`
- `cost` — `{tokens_in, tokens_out, usd, wall_seconds}`
- `outcome` — `completed | needs_clarification`
- (if `needs_clarification`) `questions[]` and `partial_work`

The daemon validates against the schema before emitting `pr_ready`. Failures trigger automatic re-prompt up to 2 times.

### 8.4 Blueprint ↔ Handoff comparison (the trust loop)

Once a Handoff lands, the daemon diffs it against the Blueprint:
- Files touched not in Blueprint → 🟡 deviation flag in PWA
- Migrations executed that Blueprint didn't predict → 🟠 surfaced prominently
- New dependencies added that Blueprint missed → 🟠 surfaced
- Risk surfaces that materialized but weren't predicted → logged for model tuning

These deviations are shown in the PR review screen as `Blueprint deviations (2)`. Over time the Blueprint→Handoff diff dataset becomes the training signal that makes Blueprints more accurate.

## 9. The Triage Router (Tier 1)

Runs first, before Blueprint, on every new ticket. Cheap Haiku-class call (~$0.0003/ticket). Outputs the routing decision and feeds the Blueprint stage:

| Tier | Triage sees | Inbox chip | What happens |
|---|---|---|---|
| **Gold** | Goal + AC + constraints + scope present | 🟢 `dispatch` | Blueprint generated → dispatch flow |
| **Silver** | Goal + intent, 1–2 minor gaps | 🟡 `plan-and-dispatch` | Blueprint generated → agent produces a written plan first; human approves plan, then code |
| **Bronze** | Goal vague OR risk areas (auth/payments/security) | 🟠 `plan-with-critique` | Blueprint generated; a critic LLM critiques the plan; human approves critiqued plan |
| **Garbage** | Missing structural prereqs | 🔴 `needs-info` | **No Blueprint.** Dispatch disabled. Missing fields surfaced with "comment on GitHub" deep-link |

Tier 1 protects Tier 2 from wasted spend: garbage tickets never reach the Blueprint stage. Triage output is cached by ticket-content-hash and only re-runs on ticket edit.

## 10. Technical architecture (current + planned)

**Built today** (commit `a20d793`):

```
iPhone PWA (HTML/CSS/JS, served by daemon)
  │ HTTPS + SSE (over Tailscale / LAN for alpha)
  ▼
Mac daemon (Node.js, ~900 LOC, zero npm deps)
  ├── Harness registry → Codex / Claude Code adapters
  ├── GitHub inbox client (assigned + review-requested via /search/issues)
  ├── Workspace ↔ repo binding (parses git origin)
  ├── Branch + commit + push + compare-URL emitter
  └── ~/.loupe/config.json (mode 0600, BYOK store)
```

**Planned for v1:**

```
+ Token auth (X-Loupe-Token, QR pairing)
+ SQLite (sessions, triage, Blueprints, Handoffs)
+ Tier-1 Triage worker (Haiku-class, cached by ticket hash)
+ Tier-2 Blueprint generator (Sonnet-class with read-only Read/Glob/Grep,
    cached by (ticket_hash, repo_HEAD_sha))
+ Brief assembler (deterministic; consumes ticket + triage + Blueprint)
+ Handoff validator (JSON Schema; auto re-prompt on miss)
+ Blueprint↔Handoff diff engine (surfaces deviations)
+ Send-back orchestrator (augment Brief, resume harness session)
+ Web Push (incl. blueprint_ready, pr_ready, needs_clarification)
+ Tauri menu-bar app (replaces "run node daemon.js")
+ .loupe/sacred.yaml loader
```

**Aspirational (v2+):**

- Native iOS app (SwiftUI) replacing PWA.
- Embeddings-based precedent retrieval (full simplicio layer).
- Linear + Jira adapters.
- Team-aware inbox (shared queue, routing).
- Team-roll-up Blueprint dashboards (PM/EM surfaces).

## 11. Token economics

### 11.1 Baseline (no contract, no triage, no Blueprint)
- Per session: 30k–150k input + 5k–30k output → **$0.10–$0.50**.
- Pass rate ~35–60% first attempt; effective **1.5–2.0 attempts per merged PR**.
- **Effective cost per merged PR: $0.40–$1.00.**

### 11.2 Cost of Tier-1 Triage
- ~500 input + ~250 output, Haiku 4.5. **~$0.0003/ticket.**
- Cached by content hash. Effectively free at any reasonable inbox size.

### 11.3 Cost of Tier-2 Blueprint
- Read-only repo pass, Sonnet-class or Haiku-with-tools. **~$0.024–$0.08/ticket** depending on repo size and ticket complexity.
- Cached by `(ticket_content_hash, repo_HEAD_sha)`. Re-runs only on ticket edit or repo move ≥ 5 commits.
- Tier-1 garbage-block saves ~20% of Blueprint spend.
- For a dev with 10 new tickets/week: **~$0.50/week per user**.

### 11.4 Cost of the Brief at dispatch
- Adds 2k–5k input tokens to the agent's system prompt.
- **Reduces** total dispatch tokens because the agent skips exploratory `Glob`/`Grep`/`Read` calls — those were the bulk of session cost.
- Net per-session input tokens: **15–25% lower** vs. no-Brief baseline.

### 11.5 Cost of the Handoff
- Forcing JSON-schema output adds ~500–1000 output tokens.
- Net output token cost: **+5–10%**.
- Net reviewer time: **–50% to –80%**.

### 11.6 The compounding effect: pass rate
- Simplicio's data: structured contracts add **+51 pp** average pass rate across 14 models.
- Conservative Loupe estimate: 40% → 80% pass rate; **attempts per merged PR drop from 2.5 → 1.25**.
- Per-merged-PR token cost drops ~50% even before per-session optimizations.

### 11.7 Per-developer monthly projection
Assumes 5 dispatches/day, 22 working days = 110 dispatches/month, 10 new tickets/week.

| Configuration | Triage | Blueprint | Avg attempts | Tokens/attempt | Cost/attempt | Monthly cost |
|---|---|---|---|---|---|---|
| Baseline (none) | — | — | 2.0 | 75k + 15k | $0.35 | **$77** |
| + Triage only | $0.03 | — | 1.7 | 75k + 15k | $0.35 | **$66** |
| + Blueprint only | — | $2.00 | 1.4 | 60k + 16k | $0.29 | **$43** |
| **+ All three (Loupe v1)** | **$0.03** | **$2.00** | **1.1** | **55k + 16k** | **$0.27** | **$35** |

**Loupe saves a single dev ~$42/month** in API spend. Across a 50-dev org: **~$25k/year** in pure API savings before counting human time.

### 11.8 Cost surfacing in the product
Every Blueprint shows its own `cost_to_generate` plus an estimated dispatch range. Every Handoff carries actual `cost`. The PWA renders:
- **Per session:** chip on session card (`$0.42 · 92s`)
- **Per day:** aggregated in inbox header (`today: 4 PRs · $1.83 · est saved 47m`)
- **Per month:** settings screen with optional budget cap

Cost transparency is a **trust feature**. Knowing what each PR cost makes the next dispatch easier.

### 11.9 What this implies for pricing
- **BYOK + per-seat ($15–25/mo)** — most likely V1 model. User pays Anthropic/OpenAI directly; Loupe charges for orchestration. Pays for itself on token savings.
- **BYOK + free** — alpha phase. Capture users; monetize later via team features.
- **Token-included ($50–80/mo + cap)** — abstract BYOK away. Higher ARPU but loses the "your tokens stay yours" trust story. Defer.

## 12. Success metrics

For the closed alpha (50 hand-picked devs over 6 weeks):

| Metric | Target | Why it matters |
|---|---|---|
| % of dispatched PRs merged | ≥ 60% | The contract is working |
| Median time from `pr_ready` to merge | ≤ 8 min | Phone-native review actually works |
| **Blueprint precision** (files predicted ÷ files actually touched) | ≥ 70% | Trust artifact is trustworthy |
| **Blueprint approval rate** (% of Blueprints that dispatch without "Adjust scope") | ≥ 50% | Blueprint is reading scope correctly |
| **% of dispatches halted at Blueprint** (user saw something wrong, didn't dispatch) | 10–25% | Healthy Blueprint utility — too low = ignored, too high = noisy |
| `verify_these` items tapped → resolved via send-back | ≥ 30% | Structured send-back is being used |
| `needs-info` tickets fixed within 24h | ≥ 50% | Triage diagnostic is actionable |
| 7-day retention | ≥ 60% | Sticky |
| Avg token cost per merged PR (incl. Blueprint) | ≤ $0.32 | §11.7 holding |
| NPS | ≥ 40 | Not just used — loved |

## 13. Privacy + security

- BYOK only. No tokens or code traverse any Loupe-operated server.
- Credentials in `~/.loupe/config.json`, mode 0600.
- Daemon requires `X-Loupe-Token` on every API call (post-F22).
- Pairing flow: short-lived QR code combining token + Tailscale/LAN endpoint.
- Brief, Blueprint, and Handoff stored on the user's Mac (`.loupe/briefs/`, `.loupe/blueprints/`, `.loupe/handoffs/`). Never uploaded.
- Tier-1 / Tier-2 LLM calls go directly from the user's Mac to their chosen provider — Loupe never sees them.
- Anonymous funnel events (dispatch_started, blueprint_generated, pr_ready, merged) logged for product analytics; opt-out in privacy-mode.

## 14. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Blueprint is confidently wrong; user dispatches with false confidence | Medium | Handoff↔Blueprint diff surfaces deviations in PR review. Blueprint deviations dataset prompt-tunes the generator. Display `blueprint_confidence` prominently. |
| Blueprint generation too slow → inbox feels laggy | Medium | Tier-1 routing shows immediately. Blueprint loads progressively with "Analyzing…" state. Cap Blueprint wall time at 30s. |
| Repo evolves between Blueprint and dispatch | Medium | Track `repo_sha_at_generation`. On dispatch tap, re-blueprint silently if HEAD has moved. |
| Users stop reading Blueprints after week 1 | Medium-High | Progressive disclosure — summary chips by default, details on tap. Notification only fires when Blueprint flags red items. |
| Adversarial ticket asks to do something destructive | Low | Dangerous risk surfaces (`data-loss`, `auth`, `security`) require confirmation modal. `.loupe/sacred.yaml` enforces forbidden paths. |
| Triage misclassifies Gold ticket as needs-info | Medium | Manual override available, logged on ticket. Confidence threshold tunable. |
| Agent silently produces wrong code despite contract | Low | Handoff `confidence < 0.6` or any high-severity `verify_these` blocks the green PR card; renders red `review-with-care`. |
| Happy / Tactic ship inbox feature before us | Medium-High | Wedge is the **Blueprint + Contract**, not the inbox. Even with copycat inboxes, Blueprint pre-flight is the moat. |
| Apple rejects iOS app for "requires external software" | Medium | Lead submission with the standalone PR review surface. Mac is an "optional enhancement." |
| User burns through API spend on runaway sessions | Low-Medium | Per-session timeout (15 min default). Daily budget cap in settings. Cost visible per session. |

## 15. Roadmap

### Phase 0 — this week (alpha-prep)
- F22 token auth + QR pairing
- F23 SQLite (sessions / triage / Blueprints / Handoffs)
- F11 Tier-1 triage routing only — no Blueprint generation yet

### Phase 1 — weeks 1–3 (closed alpha, 50 devs)
- F13–F16 Blueprint generation, caching, inbox chips, detail screen
- F17 Brief assembler
- F18 Handoff schema + validation
- F19 Blueprint↔Handoff diff with deviation surfacing
- F20 Tappable `verify_these` send-back loop
- F24 Web Push (incl. `blueprint_ready`)
- Tauri menu-bar app replaces manual `node daemon.js`
- GitHub OAuth App replaces PAT paste

### Phase 2 — weeks 4–10 (public beta, native iOS)
- F21 `needs_clarification` outcome end-to-end
- F26 `.loupe/sacred.yaml` repo config
- SwiftUI iOS app → TestFlight → App Store
- Cost-surfacing UI (F25)
- Blueprint→Handoff dataset feeds prompt tuning

### Phase 3 — months 3–6 (scale)
- Linear adapter
- Embeddings-based precedent retrieval (true simplicio layer)
- Team-aware inbox + routing
- Team-roll-up Blueprint dashboards (the PM/EM wedge)
- Webhooks for PR-state changes

### Phase 4 — months 6+
- Jira adapter
- Voice send-back
- Slack integration (agent questions → DM)
- Multi-Mac (one inbox across multiple machines)

## 16. Open questions

1. **Pricing trigger.** Free → paid switch point. My instinct: when `pr_ready` exceeds 5/week sustained. Token savings alone justify $20/mo there.
2. **Blueprint model.** Haiku-with-tools vs Sonnet-with-tools vs Codex `--exec --json` in a planning prompt. Haiku is fast and cheap but may miss subtle architectural cues. Test all three during alpha.
3. **Blueprint regeneration policy.** On every ticket edit? On every repo HEAD move? On both, but throttled? Lean: ticket edit always re-runs; repo moves trigger silent re-run only when user opens that ticket.
4. **Blueprint deviation threshold.** What % file overlap counts as "deviation"? Hard cutoff vs. fuzzy match. Start with: any new file touched not in `files_to_touch` is a deviation; missing predicted files are a soft deviation.
5. **What lives in `.loupe/sacred.yaml`?** Just `forbidden_paths` + `precedents`, or also team conventions (commit style, branch naming, test patterns)? Start narrow.
6. **Mac app distribution.** Direct DMG (faster, requires notarization + Developer ID) vs Mac App Store (sandbox restricts spawning binaries — likely blocks the harness model). Direct DMG, almost certainly.
7. **Should Blueprint screen *replace* the composer for ticket-driven dispatches, or augment it?** Replacing is more opinionated; augmenting is more flexible. Lean: replace for v1, see if users miss it.

---

## Appendix A — naming the wedge

The tagline pair lands on three levels:

- **Smart work** = AI-assisted coding (your users already do this).
- **Smarter way** = the contract + the Blueprint + the inbox + the structured loop (your differentiation).
- **See what changes before it changes anything** = the trust artifact, in seven words.

It contrasts implicitly with the "dumber way" — which is what every chat-style competitor offers: a phone keyboard, a stream of stdout, and the hope that the agent guessed right. Loupe replaces hope with structure, and surprise with preview.
