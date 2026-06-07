const fs = require("fs");
const { sessionMetrics } = require("./metrics");

function createSessionStateStore({ loupeHome, stateFile, sessions, plans }) {
  function serializeSession(session) {
    return {
      id: session.id,
      harnessId: session.harnessId,
      message: session.message,
      workspace: session.workspace,
      dispatch: session.dispatch || null,
      status: session.child ? "running" : session.status,
      events: session.events || [],
      nextEventId: session.nextEventId || 0,
      startedAt: session.startedAt,
      exitCode: session.exitCode ?? null,
      codexThreadId: session.codexThreadId || null,
      claudeSessionId: session.claudeSessionId || null,
      branch: session.branch || null,
      agentMessages: session.agentMessages || [],
      handoff: session.handoff || null,
      deviation: session.deviation || null,
      metrics: sessionMetrics(session)
    };
  }

  function persistState() {
    try {
      fs.mkdirSync(loupeHome, { recursive: true });
      const payload = {
        version: 1,
        savedAt: new Date().toISOString(),
        sessions: [...sessions.values()].map(serializeSession).slice(-100),
        plans: [...plans.values()].slice(-200)
      };
      const tmp = `${stateFile}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(payload, null, 2));
      fs.renameSync(tmp, stateFile);
      try { fs.chmodSync(stateFile, 0o600); } catch {}
    } catch (error) {
      console.warn(`Could not persist Loupe state: ${error.message}`);
    }
  }

  function hydrateState() {
    let payload = null;
    try {
      payload = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    } catch {
      return;
    }

    for (const plan of payload.plans || []) {
      if (plan?.id) plans.set(plan.id, plan);
    }

    for (const saved of payload.sessions || []) {
      if (!saved?.id) continue;
      const events = Array.isArray(saved.events) ? saved.events : [];
      const maxEventId = events.reduce((max, event) => Math.max(max, Number(event.id) || 0), -1);
      sessions.set(saved.id, {
        id: saved.id,
        harnessId: saved.harnessId,
        message: saved.message || "",
        workspace: saved.workspace || null,
        dispatch: saved.dispatch || null,
        status: saved.status === "running" ? "interrupted" : saved.status || "completed",
        events,
        clients: new Set(),
        nextEventId: Math.max(Number(saved.nextEventId) || 0, maxEventId + 1),
        startedAt: saved.startedAt || new Date().toISOString(),
        exitCode: saved.exitCode ?? null,
        codexThreadId: saved.codexThreadId || null,
        claudeSessionId: saved.claudeSessionId || null,
        branch: saved.branch || null,
        agentMessages: Array.isArray(saved.agentMessages) ? saved.agentMessages : [],
        handoff: saved.handoff || null,
        deviation: saved.deviation || null,
        child: null
      });
    }
  }

  return {
    hydrateState,
    persistState,
    serializeSession
  };
}

module.exports = {
  createSessionStateStore
};
