#!/usr/bin/env node
const assert = require("assert");
const {
  codexAgentText,
  costEventFromCodexTokenCount,
  isCodexTaskComplete,
  normalizeCodexFileChanges,
  tokenUsageFromCodexTokenCount
} = require("../daemon/harnesses/codex");

const tokenCount = {
  type: "event_msg",
  payload: {
    type: "token_count",
    info: {
      total_token_usage: {
        input_tokens: 294943,
        cached_input_tokens: 229760,
        output_tokens: 2635,
        reasoning_output_tokens: 303,
        total_tokens: 297578
      }
    }
  }
};

const usage = tokenUsageFromCodexTokenCount(tokenCount);
assert.deepStrictEqual(usage, {
  input_tokens: 65183,
  cache_read_input_tokens: 229760,
  output_tokens: 2635,
  reasoning_output_tokens: 303,
  total_tokens: 297578
});

const event = costEventFromCodexTokenCount(tokenCount, "gpt-5.5");
assert.strictEqual(event.type, "codex");
assert.strictEqual(event.kind, "token_count");
assert.strictEqual(event.costKind, "estimated_from_tokens");
assert.strictEqual(event.currency, "USD");
assert.strictEqual(event.model, "gpt-5.5");
assert.strictEqual(event.costUsd, 0.1365);

assert.strictEqual(isCodexTaskComplete({
  type: "event_msg",
  payload: { type: "task_complete", duration_ms: 74260 }
}), true);

assert.strictEqual(isCodexTaskComplete(tokenCount), false);

assert.strictEqual(codexAgentText({
  type: "response_item",
  payload: {
    type: "message",
    content: [{ type: "output_text", text: "Done." }]
  }
}), "Done.");

assert.deepStrictEqual(normalizeCodexFileChanges({
  type: "patch_apply",
  path: "daemon.js",
  patch: "@@ example @@\n-old\n+new\n+next"
}), [{
  path: "daemon.js",
  status: "modified",
  additions: 2,
  deletions: 1,
  patch: "@@ example @@\n-old\n+new\n+next"
}]);

console.log("codex cost fixture passed");
