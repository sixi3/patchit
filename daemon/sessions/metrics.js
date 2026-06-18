const { roundUsd } = require("../costs");

function eventTimeMs(event) {
  const value = Date.parse(event?.at || "");
  return Number.isFinite(value) ? value : null;
}

function sessionDurationMs(session) {
  const start = Date.parse(session.startedAt || "");
  if (!Number.isFinite(start)) return null;
  const done = [...(session.events || [])].reverse().find((event) => event.type === "done");
  const end = session.child ? Date.now() : eventTimeMs(done);
  if (!Number.isFinite(end)) return null;
  return Math.max(0, end - start);
}

function sessionExecutionCostUsd(session) {
  const result = [...(session.events || [])].reverse().find((event) =>
    typeof event.totalCostUsd === "number" || typeof event.costUsd === "number"
  );
  const value = result?.totalCostUsd ?? result?.costUsd;
  return typeof value === "number" ? roundUsd(value) : null;
}

function sessionBlueprintCostUsd(session) {
  const plan = session.dispatch?.plan || session.dispatch?.blueprint || null;
  const value = plan?.costEstimate?.blueprint?.actualUsd ?? plan?.costUsd ?? null;
  return typeof value === "number" ? roundUsd(value) : null;
}

function sessionMetrics(session) {
  const blueprintCostUsd = sessionBlueprintCostUsd(session);
  const executionCostUsd = sessionExecutionCostUsd(session);
  const costParts = [blueprintCostUsd, executionCostUsd].filter((value) => typeof value === "number");
  const costUsd = costParts.length ? roundUsd(costParts.reduce((sum, value) => sum + value, 0)) : null;
  return {
    durationMs: sessionDurationMs(session),
    costUsd,
    costKind: costUsd === null ? null : "measured",
    currency: "USD",
    blueprintCostUsd,
    executionCostUsd
  };
}

module.exports = {
  sessionBlueprintCostUsd,
  sessionDurationMs,
  sessionExecutionCostUsd,
  sessionMetrics
};
