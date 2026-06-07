const { usdFromUsage } = require("../costs");

function codexAgentText(payload, item) {
  if (item?.type === "agent_message") return item.text || item.message || "";
  if (payload?.type === "agent_message") return payload.text || payload.message || "";
  if (payload?.type === "event_msg" && payload.payload?.type === "agent_message") {
    return payload.payload.text || payload.payload.message || "";
  }
  if (payload?.type === "response_item" && payload.payload?.type === "message") {
    return textFromCodexMessagePayload(payload.payload);
  }
  return "";
}

function textFromCodexMessagePayload(message) {
  const content = message?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => typeof part === "string" ? part : part?.text || "")
    .filter(Boolean)
    .join("\n");
}

function tokenUsageFromCodexTokenCount(payload) {
  const tokenCount = payload?.type === "event_msg" && payload.payload?.type === "token_count"
    ? payload.payload
    : null;
  const total = tokenCount?.info?.total_token_usage;
  if (!total) return null;

  // Codex reports cached tokens as part of input_tokens. Loupe's cost model
  // expects fresh and cached input separately, so split them before pricing.
  const inputTotal = Number(total.input_tokens) || 0;
  const cached = Number(total.cached_input_tokens) || 0;
  return {
    input_tokens: Math.max(0, inputTotal - cached),
    cache_read_input_tokens: cached,
    output_tokens: Number(total.output_tokens) || 0,
    reasoning_output_tokens: Number(total.reasoning_output_tokens) || 0,
    total_tokens: Number(total.total_tokens) || 0
  };
}

function costEventFromCodexTokenCount(payload, model) {
  const usage = tokenUsageFromCodexTokenCount(payload);
  if (!usage) return null;
  const costUsd = usdFromUsage(model, usage);
  if (typeof costUsd !== "number") return null;
  return {
    type: "codex",
    kind: "token_count",
    costUsd,
    costKind: "estimated_from_tokens",
    currency: "USD",
    model,
    usage
  };
}

function isCodexTaskComplete(payload) {
  return payload?.type === "event_msg" && payload.payload?.type === "task_complete";
}

function normalizeCodexFileChanges(item) {
  const rawChanges = Array.isArray(item?.changes) && item.changes.length
    ? item.changes
    : [{ ...item, path: item?.path || item?.file || item?.filename }];

  return rawChanges.map((change) => {
    const path = change.path || change.file || change.filename || "";
    const patch = String(change.patch || change.diff || change.unified_diff || "");
    const stats = diffStats(patch);
    return {
      path,
      status: change.status || change.change_type || change.kind || (item?.type === "patch_apply" ? "modified" : "modified"),
      additions: numberOr(stats.additions, change.additions, change.added),
      deletions: numberOr(stats.deletions, change.deletions, change.removed),
      patch: patch.slice(0, 4000)
    };
  }).filter((change) => change.path || change.patch);
}

function diffStats(patch) {
  if (!patch) return { additions: 0, deletions: 0 };
  let additions = 0;
  let deletions = 0;
  for (const line of String(patch).split(/\r?\n/)) {
    if (line.startsWith("+++") || line.startsWith("---")) continue;
    if (line.startsWith("+")) additions += 1;
    if (line.startsWith("-")) deletions += 1;
  }
  return { additions, deletions };
}

function numberOr(...values) {
  for (const value of values) {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  return 0;
}

module.exports = {
  codexAgentText,
  costEventFromCodexTokenCount,
  isCodexTaskComplete,
  normalizeCodexFileChanges,
  tokenUsageFromCodexTokenCount
};
