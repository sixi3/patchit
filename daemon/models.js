const { MODEL_PRICING, pricingFor, roundUsd, usdFromUsage } = require("./costs");

function createModelRouter({ config }) {
  function blueprintModelAlias() {
    return process.env.LOUPE_BLUEPRINT_MODEL || config.models?.blueprint || "opus";
  }

  function executionModelAlias() {
    return process.env.LOUPE_EXECUTION_MODEL || config.models?.execution || "sonnet";
  }

  function codexExecutionModelAlias() {
    return process.env.LOUPE_CODEX_EXECUTION_MODEL || config.models?.codexExecution || "gpt-5.5";
  }

  function executionModelAliasForHarness(harnessId) {
    return harnessId === "codex" ? codexExecutionModelAlias() : executionModelAlias();
  }

  function blueprintModelForTicket(ticket) {
    const override = process.env.LOUPE_BLUEPRINT_MODEL || config.models?.blueprint;
    if (override) return override;
    const hay = `${(ticket?.labels || []).join(" ")} ${ticket?.title || ""} ${ticket?.body || ""}`.toLowerCase();
    const risky = ["auth", "login", "password", "token", "oauth", "payment", "billing",
      "stripe", "charge", "refund", "security", "vulnerab", "migration", "schema",
      "encrypt", "crypto", "permission", "privacy", "pii"].some((k) => hay.includes(k));
    return risky ? "opus" : "sonnet";
  }

  function estimateExecutionCost(blueprint) {
    if (!blueprint || blueprint.outcome !== "ready") return null;
    const size = ["S", "M", "L", "XL"].includes(blueprint.size) ? blueprint.size : "M";
    const bucket = EXEC_TOKENS[size];
    const fileCount = Array.isArray(blueprint.files) ? blueprint.files.length : 0;
    const riskCount = Array.isArray(blueprint.riskAreas) ? blueprint.riskAreas.length : 0;
    const factor = 1 + Math.max(0, fileCount - 3) * 0.08 + riskCount * 0.12;
    const model = executionModelAliasForHarness(blueprint.defaultAgent === "claude" ? "claude-code" : "codex");
    const p = pricingFor(model) || MODEL_PRICING.sonnet;
    const inLow = Math.round(bucket.inLow * factor);
    const inHigh = Math.round(bucket.inHigh * factor);
    return {
      lowUsd: roundUsd((inLow * p.in + bucket.out * p.out) / 1e6),
      highUsd: roundUsd((inHigh * p.in + bucket.out * 1.5 * p.out) / 1e6),
      currency: "USD",
      model,
      tokensLow: inLow + bucket.out,
      tokensHigh: inHigh + Math.round(bucket.out * 1.5),
      calibrated: false,
      basis: `estimate:${model}`
    };
  }

  function blueprintCostEstimate(blueprint) {
    const measured = usdFromUsage(blueprint?.model, blueprint?.usage);
    const actual = measured ?? (typeof blueprint?.costUsd === "number" ? roundUsd(blueprint.costUsd) : null);
    const execution = estimateExecutionCost(blueprint);
    const u = blueprint?.usage || null;
    return {
      blueprint: {
        actualUsd: actual,
        currency: "USD",
        measured: actual !== null,
        provider: blueprint?.provider || null,
        model: blueprint?.model || null,
        tokens: u ? {
          input: u.input_tokens ?? u.inputTokens ?? null,
          output: u.output_tokens ?? u.outputTokens ?? null,
          cached: u.cache_read_input_tokens ?? u.cacheReadInputTokens ?? null
        } : null
      },
      execution,
      total: execution ? {
        lowUsd: roundUsd((actual || 0) + execution.lowUsd),
        highUsd: roundUsd((actual || 0) + execution.highUsd),
        currency: "USD",
        includesEstimatedBlueprint: actual === null
      } : null
    };
  }

  return {
    blueprintCostEstimate,
    blueprintModelAlias,
    blueprintModelForTicket,
    codexExecutionModelAlias,
    estimateExecutionCost,
    executionModelAlias,
    executionModelAliasForHarness
  };
}

const EXEC_TOKENS = {
  S:  { inLow: 25_000,  inHigh: 60_000,  out: 4_000 },
  M:  { inLow: 60_000,  inHigh: 150_000, out: 10_000 },
  L:  { inLow: 150_000, inHigh: 350_000, out: 25_000 },
  XL: { inLow: 350_000, inHigh: 800_000, out: 60_000 }
};

module.exports = {
  createModelRouter
};
