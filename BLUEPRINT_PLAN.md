# Loupe — Blueprint Phase 1 Implementation Plan

**Status:** Designed, not yet implemented
**Owner:** sixi3
**Target:** 5 working days to shipping T1 Blueprint in the inbox with provider abstraction baked in
**References:** `blueprint.prompt.md`, `blueprint.schema.json`, `PRD.md` §8.1

---

## 1. What this delivers

After 5 days of focused work:

- Every assigned GitHub issue in your inbox arrives with a **Blueprint** showing predicted files, dependencies, migrations, risk areas, and an open-questions list — generated automatically before you tap.
- Garbage tickets (no AC, no repro steps) are caught at the door with a `needs_info` state that blocks dispatch and surfaces what's missing.
- After dispatch completes, the **Handoff** the agent produces is compared against the Blueprint; deviations surface in the review screen.
- The accumulating Blueprint→Handoff dataset begins compounding from Day 4.
- The implementation is **provider-agnostic from Day 1** via a `PlanningProvider` interface — Claude CLI ships first, OpenAI / direct-API providers slot in later as a focused 2–3 day extension, not a rewrite.

---

## 2. Research synthesis

Six findings shaped the design:

1. **Claude Agent SDK supports `--json-schema` natively** with constrained decoding + auto-retry on validation failure. CLI: `claude -p --output-format json --json-schema @blueprint.schema.json`. Guaranteed schema compliance.
2. **OpenAI Responses API supports `response_format: { type: "json_schema", strict: true }`** for the same guarantee via the direct API path.
3. **Aider's repo-map** does PageRank ranking on a file-dependency graph, token-budgeted to ~1k. We use Glob+Grep as a cheap substitute for the alpha; tree-sitter can come later.
4. **GitHub Copilot Workspace** uses two-stage planning (spec → file-level actions). We borrow the file-level-actions shape but skip the spec stage — our schema is the spec.
5. **SWE-bench Verified** gives us a labeled dataset (`problem_statement` → `patch`) for the Day 5 eval harness. Format: `{instance_id, repo, base_commit, problem_statement, hints_text, patch}`.
6. **Plan mode in Claude Code** adds 142–1,297 tokens of read-only constraints to the system prompt. Our prompt mirrors that pattern.

---

## 3. Architecture

### 3.1 Component map

```
Inbox fetch
  ↓
For each ticket without a fresh blueprint cache hit:
  ↓
PlanningProviderRegistry.get(provider_id)
  ↓
provider.generateBlueprint({ prompt, schema, cwd, ticket })
  ↓
  ┌──────────────────────────────────────────────────┐
  │ Implementations:                                  │
  │  - ClaudeCliProvider    (Phase 1, this sprint)   │
  │  - OpenAIResponsesProvider  (Phase 2, ~2-3 days) │
  │  - AnthropicMessagesProvider  (Phase 3)          │
  │  - CodexCliProvider     (Phase 3)                │
  │  - GeminiProvider       (Phase 4+)               │
  └──────────────────────────────────────────────────┘
  ↓
Validated Blueprint JSON
  ↓
Cache to .loupe/blueprints/<ticket_hash>.<repo_sha>.json
  ↓
Stream to PWA via SSE
  ↓
Render chips on inbox card
```

### 3.2 The `PlanningProvider` interface

The single most important design decision in this plan. Everything else slots into this shape:

```js
// planning-providers/base.js
class PlanningProvider {
  /**
   * @returns {string} stable id, e.g. "claude-cli", "openai-api"
   */
  get id() { throw new Error("subclass must implement"); }

  /**
   * @returns {string} human label for UI, e.g. "Claude Code (CLI)"
   */
  get label() { throw new Error("subclass must implement"); }

  /**
   * @returns {boolean} can this provider run right now given current config?
   */
  isAvailable() { throw new Error("subclass must implement"); }

  /**
   * @param {object} args
   * @param {string} args.systemPrompt  — rendered Blueprint system prompt
   * @param {object} args.schema         — Loupe Blueprint JSON Schema
   * @param {string} args.userPrompt     — ticket block (title/body)
   * @param {string} args.cwd            — workspace path (also tool sandbox root)
   * @param {object} args.ticket         — for cache keying + telemetry
   * @returns {Promise<{ structured_output, cost_usd, duration_ms, model, provider }>}
   */
  async generateBlueprint({ systemPrompt, schema, userPrompt, cwd, ticket }) {
    throw new Error("subclass must implement");
  }
}
```

The **prompt and schema are constants across providers**. Each provider's job is to faithfully translate (`systemPrompt`, `schema`, `tools`, `userPrompt`) into its native API call and return validated structured output.

### 3.3 Provider availability + selection

```js
// In daemon.js
function getActivePlanningProvider() {
  const requested = config.blueprint?.provider; // user setting
  const available = REGISTRY.filter((p) => p.isAvailable());

  if (requested) {
    const match = available.find((p) => p.id === requested);
    if (match) return match;
  }

  // Default preference order
  const order = ["claude-cli", "openai-api", "anthropic-api", "codex-cli"];
  for (const id of order) {
    const match = available.find((p) => p.id === id);
    if (match) return match;
  }
  return null;
}
```

If no provider is available (e.g., user has only OpenAI execution config but no Anthropic/OpenAI planning config), the inbox shows tickets without blueprints + an "Enable Blueprint" CTA in settings.

### 3.4 Read-only tool layer (for direct-API providers)

Each direct-API provider needs to implement the Read/Glob/Grep tools the system prompt references. ~150 LOC shared utility:

```js
// planning-providers/local-tools.js
function makeReadToolImpl(cwd) {
  return async ({ file_path, offset, limit }) => {
    const abs = path.resolve(cwd, file_path);
    if (!abs.startsWith(cwd)) throw new Error("path escapes workspace");
    const content = fs.readFileSync(abs, "utf8");
    return { content: sliceLines(content, offset, limit) };
  };
}
// Similar for makeGlobToolImpl, makeGrepToolImpl
```

Read-only by construction — these tools have no write capability. The model can't even attempt destructive actions.

CLI-based providers (Claude CLI, Codex CLI) inherit the harness's built-in tool implementations; they get tool restriction via flags (`--allowedTools "Read,Glob,Grep"` for Claude).

---

## 4. The artifacts

Already on disk in the repo:

- **`blueprint.prompt.md`** — the system prompt, paste-ready. Templated with `{repo}`, `{workspace_path}`, `{repo_sha}` for the daemon to interpolate.
- **`blueprint.schema.json`** — the JSON Schema. Used identically by every provider for output validation.

Source of truth for prompt + schema is the file system, not embedded strings in `daemon.js`. This lets us iterate the prompt without redeploying the daemon code, and lets the eval harness load the same files the runtime uses.

---

## 5. Day-by-day implementation

### Day 1 — `ClaudeCliProvider` + cache layer

**Goal:** `generateBlueprint(ticket, workspace)` returns a validated Blueprint JSON. No PWA changes.

**Files touched:**
- `daemon.js` — add ~200 LOC for the registry, ClaudeCliProvider, generateBlueprint wrapper
- New: `planning-providers/base.js`, `planning-providers/claude-cli.js`
- New: `.loupe/blueprints/` directory for cache

**Implementation outline:**

```js
// planning-providers/claude-cli.js
class ClaudeCliProvider extends PlanningProvider {
  get id() { return "claude-cli"; }
  get label() { return "Claude Code (CLI)"; }

  isAvailable() {
    return !!getHarness("claude-code")?.available;
  }

  async generateBlueprint({ systemPrompt, schema, userPrompt, cwd, ticket }) {
    const claudeBin = getHarness("claude-code").bin;
    const schemaPath = path.join(LOUPE_HOME, "schemas", "blueprint.schema.json");
    fs.mkdirSync(path.dirname(schemaPath), { recursive: true });
    fs.writeFileSync(schemaPath, JSON.stringify(schema));

    const args = [
      "-p", userPrompt,
      "--append-system-prompt", systemPrompt,
      "--output-format", "json",
      "--json-schema", `@${schemaPath}`,
      "--allowedTools", "Read,Glob,Grep",
      "--permission-mode", "dontAsk",
      "--add-dir", cwd,
      "--max-turns", "15"
    ];

    return new Promise((resolve, reject) => {
      const child = spawn(claudeBin, args, {
        cwd,
        env: { ...process.env, NO_COLOR: "1", FORCE_COLOR: "0" },
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 60_000
      });
      let stdout = "", stderr = "";
      child.stdout.on("data", (c) => stdout += c);
      child.stderr.on("data", (c) => stderr += c);
      child.on("close", (code) => {
        if (code !== 0) return reject(new Error(`Claude CLI exit ${code}: ${stderr.slice(0,500)}`));
        try {
          const result = JSON.parse(stdout);
          const structured = result.structured_output;
          if (!structured?.outcome) return reject(new Error("Missing structured_output"));
          resolve({
            structured_output: structured,
            cost_usd: result.total_cost_usd ?? null,
            duration_ms: result.duration_ms ?? null,
            model: result.model ?? "claude-sonnet",
            provider: this.id
          });
        } catch (e) {
          reject(new Error(`Parse fail: ${e.message}. Output: ${stdout.slice(0,300)}`));
        }
      });
    });
  }
}
```

```js
// daemon.js
const PLANNING_REGISTRY = [
  new ClaudeCliProvider(),
  // Phase 2: new OpenAIResponsesProvider(),
];

const BLUEPRINT_PROMPT = fs.readFileSync(path.join(ROOT, "blueprint.prompt.md"), "utf8");
const BLUEPRINT_SCHEMA = JSON.parse(fs.readFileSync(path.join(ROOT, "blueprint.schema.json"), "utf8"));

async function generateBlueprint(ticket, workspace) {
  fs.mkdirSync(BLUEPRINT_DIR, { recursive: true });
  const cachePath = blueprintCachePath(ticket, workspace);

  try {
    const cached = JSON.parse(fs.readFileSync(cachePath, "utf8"));
    return { ...cached, _cached: true };
  } catch {}

  const provider = getActivePlanningProvider();
  if (!provider) {
    return { outcome: "error", error: "No planning provider configured" };
  }

  const systemPrompt = BLUEPRINT_PROMPT
    .replace("{repo}", ticket.repo)
    .replace("{workspace_path}", workspace.path)
    .replace("{repo_sha}", repoHeadSha(workspace));

  const userPrompt = `# Ticket: ${ticket.repo}#${ticket.number}\n\n## Title\n${ticket.title}\n\n## Body\n${ticket.body || "(empty)"}`;

  const result = await provider.generateBlueprint({
    systemPrompt,
    schema: BLUEPRINT_SCHEMA,
    userPrompt,
    cwd: workspace.path,
    ticket
  });

  const payload = {
    ...result.structured_output,
    _generated_at: new Date().toISOString(),
    _repo_sha: repoHeadSha(workspace),
    _ticket_hash: ticketHash(ticket),
    _provider: result.provider,
    _model: result.model,
    _cost_usd: result.cost_usd,
    _duration_ms: result.duration_ms
  };
  fs.writeFileSync(cachePath, JSON.stringify(payload, null, 2));
  return payload;
}
```

**Acceptance test (end of Day 1):**

```bash
node -e '
const d = require("./daemon.js");
d.generateBlueprint(
  { id: "test1", repo: "sixi3/patchit", number: 42,
    title: "Add refresh icon to inbox refresh button",
    body: "Need a small icon in the button.",
    updatedAt: "2026-05-27T00:00:00Z" },
  { path: "/Users/anandmenon/Documents/Dash" }
).then(bp => console.log(JSON.stringify(bp, null, 2)));
'
```

Must return JSON with `outcome: "ready"`, `files[]` containing `index.html`, `size: "S"`, `_provider: "claude-cli"`, and `_cost_usd` ≤ $0.10.

---

### Day 2 — Wire to inbox endpoint + render chips

**Goal:** `/api/github/inbox` enriches each ticket with `blueprint` field. PWA inbox card renders the file/dep/migration chips.

**Daemon changes:**

In `/api/github/inbox` handler, after fetching tickets, kick off blueprint generation. For Day 2 keep it synchronous in the response (Day 3 makes it async):

```js
const enriched = await Promise.all(assigned.map(async (ticket) => {
  const binding = bindingFor(ticket.repo);
  if (!binding) return { ...ticket, blueprint: null };
  const workspace = workspaces.find((w) => w.id === binding.workspaceId);
  try {
    const bp = await Promise.race([
      generateBlueprint(ticket, workspace),
      new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), 30_000))
    ]);
    return { ...ticket, blueprint: bp };
  } catch (e) {
    return { ...ticket, blueprint: { outcome: "error", error: e.message } };
  }
}));
```

**PWA changes:**

Inbox card renders chips below the body:

```html
<div class="blueprint-chips">
  <span class="chip">{bp.files.length} files</span>
  {bp.deps.length > 0 && <span class="chip warn">+{bp.deps.length} deps</span>}
  {bp.migrations.length > 0 && <span class="chip warn">+migration</span>}
  <span class="chip">{bp.size}</span>
  {bp.risk_areas.map(r => <span class="chip risk">{r}</span>)}
</div>
<div class="file-chips">
  {bp.files.slice(0, 3).map(f =>
    <span class="file-chip">{f.is_new ? "~" : ""}{path.basename(f.path)}</span>
  )}
  {bp.files.length > 3 && <span class="file-chip">+{bp.files.length - 3} more</span>}
</div>
```

**Acceptance:** open inbox on phone, see file/dep/migration chips populate within 30s on first fetch, instant on cached refresh.

---

### Day 3 — Streaming + needs_info variant

**Goal:** Progressive disclosure on first load; clear blocking UX for `needs_info`.

**Daemon changes:**

Inbox endpoint returns immediately with `blueprint: { status: "generating" }` for new tickets and kicks off generation in background. PWA subscribes via SSE to `/api/blueprints/events` and updates the card when `blueprint_ready` fires.

For mid-generation streaming, use Claude's `--output-format stream-json --include-partial-messages`. Parse partial JSON deltas as they arrive. Push partial updates to PWA: `outcome` resolves first (~3s), `files` populate next (~10s), full schema by ~20–30s.

**PWA changes:**

Three card states:
1. **`generating`** — skeleton shimmer where chips will be, "analyzing codebase…" with elapsed timer
2. **`partial`** — chips populate progressively as the event stream fills them
3. **`ready`** — all chips, Dispatch enabled

For `outcome: "needs_info"`:
- Replace dispatch CTA with red "Needs info" pill
- Show `missing_info[]` as bullet list
- Button "Comment on GitHub" deep-links to a pre-filled comment template:
  `https://github.com/{repo}/issues/{n}#issuecomment-new?body=Hi%20—%20to%20dispatch%20I%20need:%0A-%20{missing[0]}%0A-%20{missing[1]}`

**Acceptance:** open inbox fresh, see chips populate one section at a time. Vague ticket shows needs_info card with missing fields and working comment link.

---

### Day 4 — Handoff schema + Blueprint↔Handoff deviation

**Goal:** Every dispatch produces a structured Handoff; deviations from Blueprint surface in the session view.

**New file: `handoff.schema.json`** (full schema in `PRD.md` §8.3; key fields: `outcome`, `tldr`, `what_i_did[]`, `decisions[]`, `verify_these[]`, `test_plan`, `confidence`, optional `questions[]` for needs_clarification).

**Daemon changes:**

In `createSession`, when dispatch comes from a ticket, pass the handoff schema to the agent via `--json-schema` (Claude) or prompt-injected instruction (Codex). The agent's final message is the structured Handoff.

In `finalizeBranch`, parse the Handoff. Compute deviation:

```js
function compareBlueprintHandoff(blueprint, handoff) {
  const plannedFiles = new Set(blueprint.files.map(f => f.path));
  const actualFiles = new Set(handoff.what_i_did.map(c => c.file));
  return {
    files_touched_not_predicted: [...actualFiles].filter(f => !plannedFiles.has(f)),
    files_predicted_not_touched: [...plannedFiles].filter(f => !actualFiles.has(f)),
    migrations_predicted: blueprint.migrations.length,
    migrations_done: handoff.what_i_did.filter(c => /migrations?\//.test(c.file)).length,
    confidence_delta: handoff.confidence.overall - blueprint.blueprint_confidence
  };
}
```

Emit `deviations_computed` event. Prepend the structured Handoff (formatted as markdown) to the PR body via the GitHub API so the PR description leads with the Handoff, not the auto-commit subject.

**PWA changes:**

Session view's PR-ready card gains a "Deviations" section: yellow chips for files-touched-not-predicted, blueprint-deviation badges per file. Each tappable to scroll to that file in the diff.

**Acceptance:** dispatch the next test ticket. PR body on GitHub starts with the structured Handoff. Session view shows deviation chips. Dataset starts accumulating.

---

### Day 5 — Eval harness + prompt iteration

**Goal:** Stop guessing whether the prompt works. Measure it.

**New script: `eval-blueprint.js`**

```js
const FIXTURES = [
  {
    name: "refresh-icon",
    ticket: { repo: "sixi3/patchit", number: 1,
      title: "Add refresh icon to inbox refresh button",
      body: "...", updatedAt: "..." },
    workspace: { path: "/Users/anandmenon/Documents/Dash" },
    expected: {
      outcome: "ready",
      files_must_include: ["index.html"],
      files_must_not_include: ["daemon.js"],
      migrations_required: false,
      deps_required: 0
    }
  },
  // 7-9 more — mix of Loupe-dispatched tickets that merged + a few SWE-bench Verified samples
];

async function evalAll() {
  const results = [];
  for (const fixture of FIXTURES) {
    const bp = await generateBlueprint(fixture.ticket, fixture.workspace);
    results.push({ name: fixture.name, score: scoreBlueprint(bp, fixture.expected), blueprint: bp });
  }
  console.log(formatReport(results));
}
```

**Seed fixtures from SWE-bench Verified** for cross-codebase signal:

```python
# one-time helper
from datasets import load_dataset
ds = load_dataset("princeton-nlp/SWE-bench_Verified", split="test")
# Sample 3-5 small ones where you can clone the repo locally
```

For each: clone repo, checkout `base_commit`, run Blueprint, compare `files[].path` against the actual `patch`'s touched files. Compute precision/recall.

**Process for Day 5:**
1. Run eval, get baseline pass rate (likely 50–70%)
2. For each failure: prompt issue? schema issue? model limitation?
3. Iterate on `blueprint.prompt.md` — usually one specific instruction fixes a class of failures
4. Re-run, measure improvement, commit prompt version with delta noted
5. Target: ≥80% pass rate across fixtures before moving to Phase 2

**Acceptance:** `eval-blueprint.js` runs cleanly, reports a pass/fail score, prompt is committed at version 1.0 with that score in the commit message.

---

## 6. Provider roadmap (Phases 2+)

### Phase 2 — `OpenAIResponsesProvider` (~2–3 days)

The most-requested second provider based on BYOK realities. Many devs have OpenAI keys but not Anthropic, or want `gpt-5-mini` for cheaper blueprints.

Implementation:
- Direct API call to OpenAI Responses API
- Pass schema via `response_format: { type: "json_schema", json_schema: { schema, strict: true } }`
- Build out `local-tools.js` (Read, Glob, Grep implementations as Node functions, ~150 LOC)
- Hand-roll the agent loop: while model returns tool calls, execute locally, return results, continue
- Reads same `blueprint.prompt.md` and `blueprint.schema.json` as Claude path

Same Blueprint output. User picks via `LOUPE_BLUEPRINT_PROVIDER=openai-api`.

### Phase 3 — `AnthropicMessagesProvider` and `CodexCliProvider` (~2 days each)

- **AnthropicMessagesProvider**: direct Messages API call. Cheaper than Claude CLI for the same model (no Claude Code SDK overhead). Reuses `local-tools.js`.
- **CodexCliProvider**: wraps `codex exec --json`. No native schema enforcement on CLI; we inject the schema as prompt and post-validate with up to 2 retries. Lower reliability than the constrained-decoding path.

### Phase 4+ — `GeminiProvider`, local-model providers

Gate on user demand. Local models (Llama, Qwen) have real accuracy concerns even with constrained-decoding libraries; not worth shipping until users specifically ask.

---

## 7. Operational details

### Cache invalidation

Cache key: `(ticket_content_hash, repo_HEAD_sha)`. Invalidates when:
- Ticket title/body/AC changes (re-hash) — re-runs on next inbox fetch
- Repo HEAD moves ≥ 5 commits (configurable threshold) — re-runs silently on next user interaction with the ticket
- User taps "Re-blueprint" explicitly — bypasses cache

### Cost monitoring

Track per-day spend:

```bash
find ~/.loupe/blueprints -name '*.json' -newer ~/.loupe/blueprints/.daily_marker \
  -exec jq '._cost_usd // 0' {} + | awk '{s+=$1} END {print "Today: $" s}'
```

If >$10/day during alpha, cache is broken (regenerating too often) or prompt is over-exploring (tool-call cap not respected).

### Failure modes to expect

| Symptom | Likely cause | Fix |
|---|---|---|
| Blueprint hallucinates fake file paths | Prompt confidence floor not strict enough | Tighten "≥ 0.7" instruction, add example |
| Always returns `outcome: "ready"` | Needs_info triggers not concrete enough | Add 2 example needs_info tickets in prompt |
| Cost spikes to $0.30+ per ticket | Tool-call cap not respected | Enforce via `--max-turns 15` + reinforce in prompt |
| Same blueprint for different repos | Cache key wrong | Verify `repoHeadSha` is per-workspace |
| Schema validation retries 3× then errors | Schema too restrictive | Loosen `maxItems`, remove unnecessary `required` fields |
| Direct-API provider hangs | Agent loop missing terminator | Add max-iteration cap + tool-call timeout in `local-tools.js` |

### Switching models within a provider

Each provider exposes a model config:

```bash
# Use cheaper Haiku for fast blueprints
export LOUPE_PLANNING_MODEL=claude-haiku-4-5

# Use frontier for deep blueprints (Phase 2+, on-tap)
export LOUPE_DEEP_PLANNING_MODEL=claude-opus-4-7
```

The same prompt + schema works across models within a provider. Quality varies but the contract holds.

---

## 8. What this plan does NOT cover

- Deep Blueprint (T2) on-tap path — design exists in `PRD.md` §8.1, defer to Phase 2.
- `.loupe/sacred.yaml` repo config loader — Blueprint already reads it via the prompt; full enforcement (auto-reject dispatches that touch forbidden paths) comes later.
- Team-wide Blueprint dashboards — `PRD.md` §15 Phase 3.
- Fine-tuned Blueprint model trained on accumulated Blueprint→Handoff diffs — `PRD.md` long-term play.

---

## 9. Summary

| Day | Deliverable | Acceptance |
|---|---|---|
| 1 | `ClaudeCliProvider` + `generateBlueprint()` + cache | Manual call returns valid Blueprint at ~$0.05 |
| 2 | Inbox endpoint enrichment + PWA card chips | Inbox on phone shows chips within 30s |
| 3 | Streaming + needs_info variant | Progressive chip render; needs_info blocks dispatch with comment-on-GitHub deep-link |
| 4 | Handoff schema + Blueprint↔Handoff deviation diff | PR body leads with structured Handoff; deviations chip in session view |
| 5 | Eval harness + prompt iteration | `eval-blueprint.js` reports ≥80% pass rate; prompt committed at v1.0 |

The PlanningProvider abstraction is built on Day 1 even though only one provider exists, making Phase 2 a 2–3 day extension instead of a 1-week rewrite. The Blueprint→Handoff dataset starts accumulating on Day 4, which is when the long-term data play begins to compound.
