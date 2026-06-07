// Shared cost utilities for measured and estimated Loupe run costs.

// Per-million-token USD pricing (May 2026). Update as prices move.
const MODEL_PRICING = {
  opus:   { in: 5.0,  out: 25.0, cachedIn: 0.5 },   // Claude Opus 4.7
  sonnet: { in: 3.0,  out: 15.0, cachedIn: 0.3 },   // Claude Sonnet 4.6
  haiku:  { in: 1.0,  out: 5.0,  cachedIn: 0.1 },   // Claude Haiku 4.5
  codex:  { in: 1.25, out: 10.0, cachedIn: 0.125 }  // OpenAI codex-tier (approx)
};

function roundUsd(value) {
  return Math.round(Number(value || 0) * 10000) / 10000;
}

function pricingFor(model) {
  const m = String(model || "").toLowerCase();
  if (m.includes("opus")) return { tier: "opus", ...MODEL_PRICING.opus };
  if (m.includes("sonnet")) return { tier: "sonnet", ...MODEL_PRICING.sonnet };
  if (m.includes("haiku")) return { tier: "haiku", ...MODEL_PRICING.haiku };
  if (m.includes("codex") || m.includes("gpt")) return { tier: "codex", ...MODEL_PRICING.codex };
  return null;
}

function usdFromUsage(model, usage) {
  const p = pricingFor(model);
  if (!p || !usage) return null;
  const cacheRead = usage.cache_read_input_tokens ?? usage.cacheReadInputTokens ?? 0;
  const cacheWrite = usage.cache_creation_input_tokens ?? usage.cacheCreationInputTokens ?? 0;
  const input = usage.input_tokens ?? usage.inputTokens ?? 0;
  const output = usage.output_tokens ?? usage.outputTokens ?? 0;
  // Cache writes bill at ~1.25x base input (5-min TTL); reads at the cached rate.
  return roundUsd((input * p.in + cacheWrite * p.in * 1.25 + cacheRead * p.cachedIn + output * p.out) / 1e6);
}

module.exports = {
  MODEL_PRICING,
  pricingFor,
  roundUsd,
  usdFromUsage
};
