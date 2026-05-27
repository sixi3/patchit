# Loupe — Product Requirements Document

**Tagline:** *The smarter way to do smart work.*
**Subtitle:** See what your agent will change, before it changes anything.
**Version:** 0.3 (alpha — adds React Native, in-app review, GitHub OAuth)
**Status:** Mac daemon shipping; iOS native app (React Native + Expo) in build; PWA deprecated to fallback/demo surface
**Owner:** sixi3
**Last revised:** 2026-05-26

---

## 1. Problem

Engineers now have AI coding agents that can write production code. They don't have a way to **manage** those agents from anywhere but their desk, and they don't have a way to **trust** them without reading every diff.

The state of the art is three bad options:

1. **Sit at the laptop and babysit.** Wastes the agent's main advantage — asynchronous work.
2. **Phone terminals** (Happy, Tactic Remote). Stream the agent's stdout on your phone over a free-form chat. No structure, no preview, no trust gate.
3. **Cloud agent surfaces** (Claude Code on the web, Codex cloud). Lose local environment access, ticket integration, BYOK control, and the trust problem.

The deeper failure: none of them constrain the agent's inputs, predict its outputs, or shape its handoff back to a human. A vague ticket becomes a vague prompt becomes a confidently-wrong PR. The reviewer must read the entire diff because the agent gives no signal about what it was unsure of, and offers no preview of what it was about to do.

## 2. Solution in one sentence

Loupe is the **contract** between you, your tickets, and your coding agents — a **native iOS app + Mac companion** that pulls assigned GitHub issues into a phone-native inbox, generates a **Blueprint** of every change before you dispatch, runs the agent in a fresh git branch under a structured **Brief**, and lets you review the resulting **Handoff** + diff and merge — entirely inside the app, without ever opening GitHub.

## 3. Target user

**Primary persona — "Mid-senior IC at a 10–200 person engineering org."**
- Uses GitHub Issues (v1); Linear / Jira deferred.
- Already pays for Claude Max or has API access (BYOK).
- Already uses Claude Code or Codex CLI locally.
- 5–20 tickets queued at any time.
- 1–3 hours/day on "engineering management of self."
- Owns an iPhone (iOS-first; Android PWA fallback only in v1).

**Secondary persona — "Tech lead reviewing agent-authored PRs."**
- 30–60 min/day on PR review.
- Wants authors (human or agent) to surface uncertainty.
- Will pay for **Blueprint visibility into team members' dispatches** before they run.

**Explicit non-targets for v1:** enterprises with on-prem requirements, Jira-only teams, Android-first users, multi-Mac users.

## 4. Competitive landscape and wedge

| Product | Lead surface | What they own |
|---|---|---|
| Happy ([happy.engineering](https://happy.engineering/)) | Phone terminal + voice | Chat polish, App Store presence, E2E encryption |
| Tactic Remote ([tacticremote.com](https://tacticremote.com/)) | Menu-bar Mac + iOS terminal control | Multi-harness monitor, mDNS auto-pair |
| Claude Code on the web | Cloud sandboxed runs | Zero-setup, no local Mac |
| GitHub Copilot Workspace | PR-stage AI suggestions | GitHub-native, deep diff context |
| **Loupe** | **Inbox → Blueprint → Brief → Handoff → in-app merge** | **The full agent workflow, end-to-end in one app** |

Loupe does not compete on terminal polish. Loupe competes on:

1. **Inbox-first information architecture** — tickets are the noun.
2. **The Blueprint** — pre-dispatch, codebase-aware preview. *No competitor has this.*
3. **The Contract** — Brief (inbound) + Handoff (outbound), structured and validated.
4. **Triage routing** — bad tickets caught at the door.
5. **In-app review and merge** — Handoff renders next to a syntax-highlighted diff; Approve + Face ID merges via the GitHub API. **Never leaves the app for the happy path.**
6. **Send-back as a structured loop** — tap a `verify_these` flag, agent resumes on the same branch, new commit appears in the same review screen.

## 5. Goals and non-goals

### Goals (v1, 4 weeks to demoable alpha, 6–8 weeks to public beta)
- A native iOS app where a developer reviews assigned GitHub issues, sees a Blueprint, dispatches to a local Codex/Claude, reviews the resulting Handoff + diff **inside the app**, and approves+merges with Face ID — without opening GitHub Mobile in the happy path.
- GitHub auth via OAuth device flow (no PAT pasting).
- Garbage tickets caught at triage and blocked from dispatch with specific missing fields.
- Every PR ships with a structured Handoff rendered in-app and pre-filled into the GitHub PR body.
- BYOK end-to-end. No tokens proxied through any Loupe-operated server.

### Non-goals (v1)
- Team features (shared inbox, assignment routing, role-based gating).
- Linear / Jira ticket sources.
- Inline file-level review comments (use send-back instead — Phase 2 feature).
- Multi-reviewer approval orchestration (escape-hatch to GitHub Mobile when blocked).
- Conflict resolution UI (escape-hatch to GitHub).
- Voice control.
- Native Android client.
- Cloud agent execution fallback.

## 6. Key user stories

### Story 0 — The full loop, never leaving the app
1. Anand opens Loupe on his iPhone. Face ID unlocks.
2. Inbox shows 6 items. He taps PAY-1284, chip says `🟢 dispatch · 3 files · M · ~$0.40`.
3. Blueprint screen opens. He scans, taps **Dispatch**.
4. Session view shows the agent working live for ~2 min.
5. Push notification: "PR ready in patchit."
6. He taps the notification. App opens to the **review screen**: Handoff at top (TL;DR, 2 yellow `verify_these`), unified diff below with syntax highlighting.
7. He taps a `verify_these` flag → small sheet asks if confirmed → he taps Confirm. Both flags now green.
8. He taps **Approve & merge** → Face ID → squash-and-merge runs via GitHub API → success animation → returns to inbox with PAY-1284 gone.

**Active interaction: ~45s. Wall time: under 4 min. Number of times he opened GitHub: zero.**

### Story 1 — The garbage ticket
1. DATA-71 shows 🔴 `needs-info`. Tap → "This ticket isn't ready" screen with three missing fields.
2. Tap "Comment on GitHub" → in-app Safari → posts pre-filled comment → ticket goes to `waiting on @reporter`.

### Story 2 — The Blueprint warned him
1. Anand taps a Silver ticket. Blueprint shows `src/auth/session.ts` in the file list.
2. The repo's `.loupe/sacred.yaml` lists `src/auth/*` as forbidden. Blueprint surfaces 🛑 out-of-scope warning prominently.
3. He realizes the ticket is mis-scoped, doesn't dispatch, edits the issue body in GitHub.
4. Inbox auto re-blueprints; warning is gone. He dispatches.

### Story 3 — Agent asks mid-flight
1. Anand dispatches a ticket whose Blueprint had one unresolved open question.
2. Agent halts with `outcome: needs_clarification`. Push notification: "Agent has a question."
3. He taps the structured option. Agent resumes. PR lands 3 min later.

### Story 4 — Send-back via structured flag (extends Story 0)
1. Handoff comes back with `verify_these[0]: "I assumed email_verified column exists."`
2. He taps the flag → "Send back to confirm" sheet → types "Confirmed, column exists since migration 0034" or just taps Confirm.
3. Brief augments, agent resumes via `claude --resume` on the same branch. New commit appears in the same review screen ~90s later.
4. Now both flags green. He merges.

### Story 5 — Blocked PR (escape hatch)
1. PR ready, but branch protection requires `@alice` review.
2. Approve button is disabled with banner: "Required reviewer @alice — [Open in GitHub Mobile]"
3. Tap escape hatch → review continues in GitHub Mobile. Loupe state stays in sync via webhook.

## 7. Functional requirements

| ID | Requirement | Status |
|---|---|---|
| F1 | Mac daemon auto-detects installed Codex + Claude Code binaries | ✅ Built |
| F2 | iOS app shows a harness picker; disables unavailable harnesses | 🔄 Port to RN |
| F3 | Workspace selector with create-folder support | 🔄 Port to RN |
| F4 | Daemon streams agent events over SSE in normalized shape | ✅ Built |
| F5 | GitHub inbox endpoint backed by BYOK credential | ✅ Built (PAT today, OAuth in F22) |
| F6 | Two-section inbox (assigned, review-requested) with workspace binding chips | 🔄 Port to RN |
| F7 | Dispatch from inbox uses Brief, not free-form composer | 🟡 Designed |
| F8 | Dispatch auto-branches `loupe/<slug>` on bound workspaces with clean tree | ✅ Built |
| F9 | On successful agent exit, daemon commits + pushes + emits `pr_ready` | ✅ Built |
| **F10a** | **In-app review screen renders Handoff (TL;DR, decisions, verify-these, blueprint deviations) + per-file collapsible unified diff with syntax highlighting** | 🟡 Designed |
| **F10b** | **Approve action merges via GitHub API with method selector (squash default) + Face ID/biometric** | 🟡 Designed |
| **F10c** | **Send-back inline: tap a `verify_these` flag → augment Brief sheet → resume agent on same branch** | 🟡 Designed |
| **F10d** | **Escape-hatch deep-link to GitHub Mobile when blocked (required reviewer / failing checks / conflicts)** | 🟡 Designed |
| F11 | Tier-1 Triage classifies into `{dispatch, plan-and-dispatch, plan-with-critique, needs-info}` with `missingInfo[]` | 🟡 Designed |
| F12 | `needs-info` shows red chip; dispatch disabled; "comment on GitHub" deep-link | 🟡 Designed |
| F13 | Tier-2 Blueprint generates pre-dispatch preview (files, deps, migrations, tests, risks, cost, confidence) for non-garbage tickets | 🟡 Designed |
| F14 | Blueprint cached by `(ticket_content_hash, repo_HEAD_sha)`; re-runs on ticket edit or significant repo move | 🟡 Designed |
| F15 | Inbox card shows Blueprint summary chips (files / size / cost / top risk) | 🟡 Designed |
| F16 | Tapping a ticket opens Blueprint screen before dispatch. "Dispatch" and "Adjust scope" are the CTAs | 🟡 Designed |
| F17 | Brief assembled deterministically at dispatch from ticket + triage + Blueprint; injected as system prompt | 🟡 Designed |
| F18 | Handoff conforms to schema; daemon validates and re-prompts on miss (≤ 2 retries) | 🟡 Designed |
| F19 | Handoff compared against Blueprint; deviations surfaced in review screen | 🟡 Designed |
| F20 | Agent can return `outcome: needs_clarification`; iOS shows structured options sheet | 🟡 Designed |
| F21 | Daemon authenticates all API calls via `X-Loupe-Token`; QR pairing from Mac menu bar to iPhone | 🔴 **Required pre-alpha** |
| **F22** | **GitHub auth via OAuth Device Flow — no PAT input ever required** | 🟡 Designed (§10) |
| F23 | SQLite persistence for sessions, triage, Blueprints, Handoffs, transitions | 🔴 Required pre-alpha |
| F24 | Push notifications via Expo Notifications + APNs for `pr_ready`, `needs_clarification`, `push_failed`, `blueprint_ready` | 🟡 Designed |
| F25 | Cost surfaced per session (chip), per day (inbox header), per month (settings) | 🟡 Partial |
| F26 | `.loupe/sacred.yaml` per repo defines forbidden paths + named precedents | 🟡 Designed |
| F27 | GitHub webhook updates merged-state when user merges via GitHub Mobile (escape-hatch path) | 🟡 Designed |

## 8. The three artifacts

The product's vocabulary. Same JSON keys recur across all three (`files_to_touch`, `migrations`, `verify_these`) so one schema renders in three contexts.

### 8.1 The Blueprint (pre-dispatch)
Generated at inbox-fetch by Tier-2 LLM call with read-only repo access. *"Here is what the agent will do, before it does it."* (Schema in v0.2.) Surfaces as inbox card chips + ticket-detail Blueprint screen + dispatch CTA.

### 8.2 The Brief (dispatch-time, agent-facing)
Assembled deterministically from ticket + Tier-1 triage + Blueprint + `.loupe/sacred.yaml`. Injected as `--append-system-prompt-file` for Claude, prepended for Codex. Stored at `.loupe/briefs/<task-id>.md`.

### 8.3 The Handoff (post-dispatch, agent-produced)
JSON-schema validated. Sections: `tldr`, `what_i_did`, `decisions`, `verify_these`, `test_plan`, `out_of_scope_observations`, `confidence`, `cost`, `outcome`, plus `questions[]` + `partial_work` when `outcome: needs_clarification`. Daemon validates and re-prompts on miss (≤ 2 retries).

### 8.4 Blueprint ↔ Handoff comparison (the trust loop)
Daemon diffs them and surfaces deviations in the review screen. Files touched not predicted → 🟡 flag. Migrations/dependencies missed → 🟠 surfaced. Over time the Blueprint→Handoff diff dataset becomes the training signal that improves Blueprint accuracy.

## 9. The Triage Router (Tier 1)

Cheap Haiku-class call (~$0.0003/ticket) on every new ticket. Outputs routing decision + `missingInfo[]` + `constraints[]` + `riskAreas[]` + `defaultAgent`. Cached by ticket-content-hash. Protects Tier 2 from wasted spend on garbage.

## 10. Technical architecture

### 10.1 Built today (commit `9d50e9b`)

```
iPhone PWA (deprecated; kept as Android fallback + demo URL)
  │ HTTPS + SSE
  ▼
Mac daemon (Node.js, ~900 LOC, zero npm deps)
  ├── Harness registry → Codex / Claude Code adapters
  ├── GitHub inbox client (PAT-based today)
  ├── Workspace ↔ repo binding (parses git origin)
  ├── Branch + commit + push + compare-URL emitter
  └── ~/.loupe/config.json (mode 0600, BYOK store)
```

### 10.2 New target architecture (v1)

```
┌────────────────────────────────────────────┐
│  iOS Native App (React Native + Expo)      │
│  ┌──────────────────────────────────────┐  │
│  │ Expo Router (file-based navigation)  │  │
│  │ Reanimated 3 + Gesture Handler       │  │
│  │ NativeWind v4 (Tailwind for RN)      │  │
│  │ Zustand (state) + TanStack Query     │  │
│  │ react-native-mmkv (local persist)    │  │
│  │ expo-secure-store (token storage)    │  │
│  │ expo-notifications (APNs)            │  │
│  │ expo-camera (QR pairing scan)        │  │
│  │ expo-web-browser (OAuth in-app)      │  │
│  │ expo-local-authentication (Face ID)  │  │
│  │ react-native-syntax-highlighter      │  │
│  └──────────────┬───────────────────────┘  │
└─────────────────┼──────────────────────────┘
                  │ HTTPS + SSE over Tailscale/LAN
                  │ X-Loupe-Token header (pairing)
                  ▼
┌────────────────────────────────────────────┐
│  Mac daemon (Node.js, expands ~900→~1500   │
│              LOC; SQLite added)            │
│  ┌──────────────────────────────────────┐  │
│  │ + OAuth Device Flow endpoints        │  │
│  │   POST /api/oauth/github/start       │  │
│  │   POST /api/oauth/github/poll        │  │
│  │ + Tier-1 Triage worker (Haiku)       │  │
│  │ + Tier-2 Blueprint generator         │  │
│  │   (Sonnet w/ read-only tools)        │  │
│  │ + Brief assembler                    │  │
│  │ + Handoff validator + retry          │  │
│  │ + Blueprint↔Handoff diff             │  │
│  │ + Send-back orchestrator             │  │
│  │   (claude --resume / codex resume)   │  │
│  │ + GitHub API client expansion        │  │
│  │   (diff fetch, merge, checks)        │  │
│  │ + APNs token registry                │  │
│  │ + Push notifier (via Expo Push API)  │  │
│  │ + GitHub webhook receiver            │  │
│  │ + SQLite (sessions, triage,          │  │
│  │   blueprints, handoffs, transitions) │  │
│  └──────────────────────────────────────┘  │
└────────────────────────────────────────────┘
```

### 10.3 GitHub OAuth Device Flow

**Why device flow, not classic OAuth:** the client secret can't safely live in a mobile app binary. Device flow needs only the public `client_id`, which is safe to ship. No URL scheme handler. No web redirect dance.

```
1. iOS taps "Connect GitHub"
2. App → Daemon POST /api/oauth/github/start
3. Daemon → GitHub POST /login/device/code
       (client_id, scope=repo)
4. GitHub returns:
       device_code, user_code (e.g. "ABCD-1234"),
       verification_uri_complete = github.com/login/device?user_code=ABCD-1234
       expires_in, interval
5. Daemon returns user_code + verification_uri_complete to iOS
6. iOS opens verification_uri_complete in expo-web-browser
       (sheet, not full app switch)
7. User taps Authorize on GitHub (the code is pre-filled)
8. iOS dismisses the browser sheet
9. iOS polls daemon: POST /api/oauth/github/poll (with device_code)
10. Daemon polls GitHub: POST /login/oauth/access_token
        every {interval} seconds with device_code
11. GitHub returns access_token (when user authorizes)
12. Daemon stores token in ~/.loupe/config.json (mode 0600)
13. Daemon → iOS: { ok: true, login: "anand" }
14. iOS: inbox loads
```

**Scopes requested:** `repo` (read + write code, PRs, comments). That's enough for the full v1 loop including merge. Nothing else.

**Loupe ships one GitHub OAuth App** (registered to "loupe.dev" or whoever's the owner). Its `client_id` ships with the app and daemon — safe because it's public. No `client_secret` in either place.

### 10.4 Daemon pairing (iOS ↔ Mac)

On first run, Mac daemon writes `~/.loupe/secret` (random 32-byte hex). Menu-bar app (post-alpha; today the daemon CLI does it) displays a QR code containing `loupe://pair?endpoint=https://<tailscale-or-lan>&token=<secret>`. iOS app scans with `expo-camera`, stores `{endpoint, token}` in `expo-secure-store`. Every API call thereafter sends `X-Loupe-Token: <secret>`. Daemon validates.

## 11. Token economics (unchanged from v0.2)

Per-developer monthly projection at 5 dispatches/day, 22 working days, 10 new tickets/week:

| Configuration | Triage | Blueprint | Avg attempts | Monthly cost |
|---|---|---|---|---|
| Baseline (none) | — | — | 2.0 | **$77** |
| + All three (Loupe v1) | $0.03 | $2.00 | 1.1 | **$35** |

Loupe saves a single dev ~$42/month in BYOK API spend. Across a 50-dev org: ~$25k/year before counting time.

## 12. Success metrics

For closed alpha (5 → 50 hand-picked devs over 6 weeks):

| Metric | Target | Why it matters |
|---|---|---|
| % of dispatched PRs merged | ≥ 60% | Contract is working |
| **% of merges done in-app (no GitHub Mobile)** | ≥ 70% | In-app review surface is sufficient |
| Median time from `pr_ready` to merge | ≤ 8 min | Phone-native review works |
| Blueprint precision (predicted files ∩ actual / actual) | ≥ 70% | Trust artifact is trustworthy |
| Blueprint approval rate (dispatched without "Adjust scope") | ≥ 50% | Blueprint reads scope correctly |
| % dispatches halted at Blueprint review | 10–25% | Healthy utility — too low = ignored, too high = noisy |
| `verify_these` items tapped → resolved via send-back | ≥ 30% | Structured send-back is being used |
| `needs-info` tickets fixed within 24h | ≥ 50% | Triage diagnostic is actionable |
| 7-day retention | ≥ 60% | Sticky |
| Avg token cost per merged PR (incl. Blueprint) | ≤ $0.32 | §11 holding |
| NPS | ≥ 40 | Loved |

## 13. Privacy + security

- BYOK only. No tokens or code touch a Loupe-operated server.
- Credentials at `~/.loupe/config.json` (mode 0600).
- iOS app holds only the pairing token (`expo-secure-store`, hardware-backed Keychain) + APNs token. Never the GitHub OAuth token.
- Daemon requires `X-Loupe-Token` on every API call.
- GitHub OAuth via Device Flow — no `client_secret` on the iOS side ever.
- Brief / Blueprint / Handoff stored on the user's Mac (`.loupe/briefs/`, `.loupe/blueprints/`, `.loupe/handoffs/`). Never uploaded.
- All LLM calls go direct from Mac to user's chosen provider. Loupe never sees them.
- Anonymous funnel events (`dispatch_started`, `blueprint_generated`, `pr_ready`, `merged_in_app`) logged for product analytics; opt-out in privacy mode.

## 14. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Diff viewer ships rough and feels worse than GitHub Mobile | High | Read-only unified diff with good syntax highlighting clears the bar. Auto-collapse lock files. Escape hatch one tap away. Iterate based on alpha feedback. |
| Blueprint confidently wrong → user dispatches with false confidence | Medium | Handoff↔Blueprint diff surfaces deviations. Blueprint confidence prominently shown. Send-back is one tap. |
| Blueprint generation too slow → inbox feels laggy | Medium | Tier-1 routing shows immediately. Blueprint loads progressively. 30s cap. |
| Repo evolves between Blueprint and dispatch | Medium | Track `repo_sha_at_generation`. On dispatch, re-blueprint silently if HEAD moved. |
| Apple rejects iOS app for "requires external Mac software" | Medium | Submission narrative: app is a standalone GitHub PR review tool. Mac integration is "optional dispatch enhancement." Lead with the in-app review value. |
| Device-flow OAuth confuses users on first use | Low-Medium | `verification_uri_complete` pre-fills the code. One Safari sheet, one Authorize tap, done. Onboarding includes a 10-second loom-style animation. |
| GitHub API rate limits hit during heavy alpha use | Low | 5,000 req/hr per user. Cache diffs aggressively. Batch where possible. |
| Push notifications miss on TestFlight builds | Medium | APNs sandbox cert for TestFlight, production cert for App Store. Validate both. |
| Send-back loop creates messy multi-commit PRs | Low | Each send-back is its own commit with structured message. Squash-merge by default cleans them up on merge. |
| Happy/Tactic ship inbox feature before us | Medium-High | Blueprint + in-app review is the moat. Inbox alone is undifferentiated. |
| Users dispatch agent on dirty workspace and lose work | Low | Daemon refuses to branch dirty trees; surfaces `branch:skipped` event with a clear message. (Already built.) |

## 15. Roadmap

### Phase 0 — week 0 (this week, pre-build)
- F21 token auth + pairing tokens (Mac side)
- F23 SQLite schema + migration to persist what's already in-memory
- Apple Developer Program enrollment kickoff (takes 24-48h)
- Register Loupe GitHub OAuth App

### Phase 1 — weeks 1–4 (RN alpha → first 5 then 50 users)
**See §17 for the day-by-day build plan.**

Functional scope shipping in Phase 1:
- F22 GitHub OAuth Device Flow
- F2, F3, F6 — RN ports of harness picker, workspace selector, inbox
- F11, F12 — Tier-1 triage and `needs-info` blocking
- F13, F14, F15, F16 — Blueprint generation, caching, inbox chips, detail screen
- F17, F18 — Brief assembly, Handoff validation
- F10a — In-app review screen with Handoff + diff viewer
- F10b — Approve & merge with Face ID
- F10c — Send-back from `verify_these` flag
- F10d — Escape hatch to GitHub Mobile when blocked
- F20 — `needs_clarification` round-trip
- F24 — Push notifications
- F25 — Cost surfaced per session

### Phase 2 — weeks 5–10 (public beta)
- F19 — Blueprint↔Handoff deviation visualization in review screen
- F26 — `.loupe/sacred.yaml` repo config
- F27 — GitHub webhook for external merge sync
- Inline file-level review comments
- Multi-reviewer awareness (read-only)
- Tauri menu-bar app replaces `node daemon.js` CLI
- Submit to App Store (out of TestFlight)
- Blueprint→Handoff dataset feeds prompt tuning

### Phase 3 — months 3–6 (scale)
- Linear adapter
- Embeddings-based precedent retrieval (full simplicio layer)
- Team-aware inbox + routing
- Team-roll-up Blueprint dashboards (PM/EM surfaces)
- Conflict resolution UI (optional in-app)

### Phase 4 — months 6+
- Jira adapter
- Voice send-back
- Slack integration (agent questions → DM)
- Multi-Mac (one inbox across multiple machines)

## 16. Open questions

1. **Pricing trigger.** Free → paid switch when `pr_ready` exceeds 5/week sustained. Token savings alone justify $20/mo.
2. **Blueprint model choice.** Haiku-with-tools vs Sonnet-with-tools. Test both in alpha.
3. **Diff viewer library.** Build on `react-native-syntax-highlighter` (heavier, more languages) vs roll a Shiki-based custom (faster, fewer languages day one). Lean: Shiki for top 15 languages, fall back to plain monospaced for the rest.
4. **Merge method default.** Squash (clean history) vs Merge commit (preserves agent's commit chain on send-back). Lean: Squash default, expose method picker in the approve sheet.
5. **What lives in `.loupe/sacred.yaml`?** `forbidden_paths` + `precedents` for v1. Team conventions (commit style, branch naming) later.
6. **Mac app distribution.** Direct DMG (notarization + Developer ID) vs Mac App Store (sandbox blocks spawning binaries — kills the harness model). Direct DMG.
7. **OAuth App ownership.** Anyone running Loupe shares one OAuth app's `client_id`. If GitHub revokes or rate-limits the app org-wide, every Loupe user is affected. Mitigation: ship with a fallback "use your own OAuth App" config path in settings.

---

## 17. Phase 1 implementation plan — 4 weeks to a demoable iPhone app

The centerpiece of this PRD. Day-by-day, build-by-build. Designed so the user can demo the full loop on their iPhone by end of Week 3, with Week 4 reserved for polish and the first external users.

### Week 0 — kickoff (do these before Day 1)

**These have lead time and must start now, in parallel with anything else:**

- **Enroll in Apple Developer Program** — $99/year, takes 24–48h. Without this you cannot push to TestFlight.
- **Register a GitHub OAuth App** at [github.com/settings/applications/new](https://github.com/settings/applications/new). Name "Loupe", homepage "https://loupe.dev" (or placeholder), authorization callback URL doesn't matter for Device Flow but set it to `loupe://oauth-callback` anyway. Note the `client_id`.
- **Provision Tailscale on Mac + iPhone** for the alpha pairing transport.
- **Set up an EAS account** (eas.dev/expo) and link to your Apple Developer Team ID.

### Week 1 — foundation + inbox (Days 1–5)

**Goal: TestFlight Build #1 — user signs in with GitHub via OAuth Device Flow and sees their assigned issues on their iPhone.**

| Day | Build | Daemon | Demo state |
|---|---|---|---|
| 1 | `npx create-expo-app loupe-ios --template tabs`. EAS Build init. NativeWind setup. Design tokens matching current PWA palette. Inter font. | F21 token auth: generate `~/.loupe/secret`, print QR code on startup, validate `X-Loupe-Token` on every endpoint. SQLite schema. | App boots on simulator with placeholder tabs. |
| 2 | Expo Router skeleton: 3 tabs (Inbox / Sessions / Settings), top bar with daemon-status pill. Pairing flow: camera scan → SecureStore save. | F21 cont. | App scans QR, talks to daemon, shows "Online" pill. |
| 3 | Daemon API client (TanStack Query + fetch). Health-check polling. Connection states (offline / pairing-needed / online). | F22 OAuth Device Flow endpoints: `/api/oauth/github/start` and `/poll`. Polling background task. | "Connect GitHub" button works; sheet shows code; user authorizes on github.com; flow completes; daemon stores token. |
| 4 | Inbox screen: two sections (Assigned / Reviews), pull-to-refresh, empty state. Cards show title + repo + age + workspace binding chip. | (no daemon change — F5 already built) | Inbox shows real GitHub issues from daemon. |
| 5 | Polish: skeleton loading states, error states, harness picker stub in Settings. **TestFlight Build #1**. | — | **User signs in with GitHub on their iPhone and sees their inbox. First demo.** |

**End-of-week-1 demo:** open app → scan QR → tap "Connect GitHub" → authorize on github.com → see your real inbox. **This alone is impressive and clears the "is it real" bar with anyone you show.**

### Week 2 — triage + Blueprint + dispatch (Days 6–11)

**Goal: TestFlight Build #2 — user taps a ticket, sees a Blueprint preview, dispatches it, and watches the agent run live on their phone.**

| Day | Build | Daemon | Demo state |
|---|---|---|---|
| 6 | Inbox card upgrade: tier chip (gold/silver/bronze/garbage), file-count chip, cost chip, risk-surface chip. Skeleton state while triage runs. | F11 Tier-1 triage worker: Haiku call on inbox refresh, cached by ticket-content-hash. Persist to SQLite. | Inbox cards show colored tier chips. |
| 7 | Blueprint detail screen: collapsible sections (Files / Migrations / Tests / Out-of-scope / Open questions). Confidence bar. Cost estimate row. "Dispatch" and "Adjust scope" CTAs. | F13 Blueprint generator: spawn Claude/Codex in plan-only mode with `--allowedTools "Read,Glob,Grep"`. Parse the structured JSON output. Cache by `(ticket_hash, repo_HEAD_sha)`. | Tap a ticket → see Blueprint with real predicted files. |
| 8 | "Adjust scope" sheet: add constraint, answer open question, mark file out-of-scope. Triggers re-blueprint. | F14 cache invalidation on adjust. | Adjust scope → Blueprint regenerates in ~15s. |
| 9 | Dispatch flow: tap Dispatch → spinner ("starting claude on Dash") → transition to session view. Session card animates in. | F17 Brief assembler: builds the Brief from ticket + triage + Blueprint + sacred.yaml (placeholder). | Dispatch lands; session view appears. |
| 10 | Session view: messages/files/actions tabs (port from PWA but native scroll, native gestures). Live SSE stream of agent events. Status chip animates. | (no change — F4 already built) | Watch the agent work on the phone in real time. |
| 11 | Cost chip on session card. Stop button. Error states (auth failure / rate limit). **TestFlight Build #2**. | — | **End-to-end dispatch demo: tap ticket → Blueprint → Dispatch → watch agent → see "PR ready" event (no review screen yet).** |

**End-of-week-2 demo:** the full pre-review path. You can show someone Blueprint, dispatch, and live agent activity. Most of the wow is here.

### Week 3 — review, merge, push (Days 12–18)

**Goal: TestFlight Build #3 — full loop. User reviews and merges in-app. Push notifications wake the app when work is ready.**

| Day | Build | Daemon | Demo state |
|---|---|---|---|
| 12 | Review screen scaffold: Handoff renderer at top with collapsible sections (TL;DR, what_i_did, decisions, verify_these, test_plan, confidence, cost). | F18 Handoff validator: parse JSON from agent's final message, validate against schema, re-prompt once on miss. | Tap PR-ready → see Handoff. |
| 13 | Diff fetcher: daemon `/api/github/diff?session=<id>` returns parsed unified diff from GitHub API. RN renders per-file list with `+X −Y` chips and collapse arrows. | New daemon endpoint: `GET /repos/{o}/{r}/pulls/{n}/files`, normalize patches. | See file list in review screen, tap to expand (text only for now). |
| 14 | Diff viewer: unified diff with syntax highlighting via `react-native-syntax-highlighter`. Auto-collapse `*-lock.json`, `*.lock`. "Expand 20 lines" buttons on collapsed hunks. | — | See real syntax-highlighted diffs in the app. |
| 15 | Approve sheet: merge-method selector (squash default), `expo-local-authentication` Face ID prompt, success animation. Calls daemon `/api/github/merge`. | New daemon endpoint: `PUT /repos/{o}/{r}/pulls/{n}/merge` proxy. State transitions to `merged`. | **Merge happens entirely inside the app with Face ID.** |
| 16 | Push notifications: Expo Notifications setup, APNs cert via EAS, daemon `/api/devices/register` endpoint. Daemon sends push on `pr_ready` and `needs_clarification`. | F24 push notifier. | Lock phone, wait, get notification when PR ready. |
| 17 | Send-back from flag: tap a `verify_these` flag → small sheet (predefined options + free-text) → daemon augments Brief and resumes session via `claude --resume`. New commit appears in same review screen. | F20 send-back orchestrator, brief augmenter. | Full send-back loop works end-to-end. |
| 18 | Escape hatch: when GitHub API says PR is blocked (required reviewer / failing checks / conflicts), show banner + "Open in GitHub Mobile" button. **TestFlight Build #3 — full loop**. | New: GitHub API status checks (`/repos/{o}/{r}/commits/{sha}/check-runs`). | **Full demo loop: inbox → Blueprint → Dispatch → live agent → push → Handoff + diff → Face ID merge → done. Never leaves the app.** |

**End-of-week-3 demo:** the entire pitch in 3 minutes on your iPhone. This is the demo video for the landing page.

### Week 4 — polish + first external alpha users (Days 19–25)

**Goal: TestFlight Build #4 — first 5 external alpha users on real devices.**

| Day | Focus |
|---|---|
| 19 | Onboarding flow: first-launch wizard. Daemon pairing → GitHub OAuth → harness detection ("Found Claude Code 2.1.142 and Codex 0.133") → "You're ready." Lottie/Reanimated polish on transitions. |
| 20 | Empty states and error states for every screen. Inbox-zero ("Nothing assigned to @you right now. Assign yourself an issue to dispatch."). Daemon-offline state. Workspace-not-bound state. |
| 21 | Cost aggregation: settings screen shows today / this week / this month. Inbox header chip when daily spend > threshold. Per-session cost on the session card. |
| 22 | `needs_clarification` end-to-end UX polish: notification → tap → structured option sheet with evidence-for-each-option lists. |
| 23 | Sentry + PostHog integration. Crash reporting. Funnel analytics (dispatch_started / blueprint_generated / pr_ready / merged_in_app). |
| 24 | **TestFlight Build #4**. Invite first 5 alpha users. Discord channel. Onboarding doc. |
| 25 | Triage bug fixes from alpha feedback. EAS Update for JS-only fixes (no rebuild). |

### Minimum demoable loop — Day 5, Day 11, Day 18

The build is structured so you can demo something on three milestone days:

- **Day 5 demo (1 min):** "Look — my iPhone app talks to my Mac, signed in with GitHub, here's my real inbox."
- **Day 11 demo (2 min):** "Now watch me tap a ticket. See the Blueprint — it tells me what the agent will change. I tap Dispatch. Look — the agent is working on my Mac in real time, streaming back to my phone."
- **Day 18 demo (3 min):** "Push notification — PR is ready. I tap it. Here's the Handoff, here's the diff. I review, tap Approve, Face ID, merged. I never opened GitHub."

The Day 18 demo is the pitch. Record it. Put it on the landing page. The 3-minute video does the marketing.

### Stack decisions locked

| Layer | Decision |
|---|---|
| Mobile framework | **Expo SDK 52** (React Native + Hermes) |
| Language | **TypeScript** |
| Navigation | **Expo Router** (file-based) |
| Animations | **Reanimated 3** + **Gesture Handler** |
| Styling | **NativeWind v4** |
| State | **Zustand** + **TanStack Query** |
| Local persist | **react-native-mmkv** |
| Secret storage | **expo-secure-store** |
| Camera (QR pair) | **expo-camera** |
| Web sheets (OAuth) | **expo-web-browser** |
| Biometric | **expo-local-authentication** |
| Push | **expo-notifications** |
| Icons | **lucide-react-native** |
| Syntax highlighting | **react-native-syntax-highlighter** (alpha); evaluate Shiki for v2 |
| Build / dist | **EAS Build** + **TestFlight** + **EAS Update** (OTA) |
| Error tracking | **Sentry RN SDK** |
| Analytics | **PostHog** (privacy-respecting, opt-out) |
| Daemon | **Stays as Node.js**, expands with SQLite (`better-sqlite3` — sole npm dep) and new endpoints. Tauri menu-bar wrap deferred to Phase 2. |

### Risks specific to the 4-week build

| Risk | Mitigation |
|---|---|
| Apple Developer enrollment takes longer than 48h | Already started in Week 0. Worst case: TestFlight Build #1 slips to Day 6. |
| Blueprint generator output is unstructured / unreliable | Use Claude's `--json-schema` to force structure. Sonnet, not Haiku, for tier-2 — accuracy matters more than cost. |
| Diff rendering performs poorly on large PRs | Cap initial render at 500 lines per file; "Show full file (1200 lines)" button. Virtualize file list with FlashList. |
| GitHub OAuth Device Flow is unfamiliar to users | First-launch animation showing the 3-step flow. Pre-fill the code in the URL. |
| SSE reconnect on iOS background→foreground breaks | Use TanStack Query's `refetchOnReconnect` for missed events; daemon's SSE endpoint replays from event index. |
| Push notifications unreliable on TestFlight | APNs sandbox cert for TestFlight builds; production cert for App Store. Test both. Fallback to in-app polling. |
| 4 weeks slips to 5 | Acceptable. Cut scope from Day 17 (send-back loop) — that becomes Phase 2's first feature. |

### What to delete from this PRD if/when scope slips

In strict order of dispensability:

1. Cost aggregation in settings (Day 21) — defer to Phase 2
2. Send-back from flag (Day 17) — defer to Phase 2; users use GitHub Mobile to comment
3. `needs_clarification` polish (Day 22) — accept basic behavior in alpha
4. Push notifications (Days 16–17) — pull-to-refresh works as fallback for alpha
5. Onboarding polish (Day 19) — accept terse first-launch in alpha

Do NOT cut: OAuth (F22), Inbox (F6), Blueprint (F13), Dispatch (F8), Live agent stream (F4), Handoff render (F10a), Diff viewer (F10a), Face ID merge (F10b). These are the demo.

---

## Appendix A — naming the wedge

The tagline pair:

- **Smart work** = AI-assisted coding (your users already do this).
- **Smarter way** = the contract + Blueprint + inbox + structured loop (your differentiation).
- **See what changes before it changes anything** = the trust artifact, in seven words.

The native app + in-app review crystallizes a second one-liner:

> **Review and merge agent PRs on your phone. Without opening GitHub.**

That's the elevator pitch. Pair it with the Day 18 demo video and the product sells itself.
