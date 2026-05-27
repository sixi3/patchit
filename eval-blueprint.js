#!/usr/bin/env node

const {
  createBlueprint,
  normalizeBlueprint,
  validateBlueprint,
  compareBlueprintHandoff
} = require("./daemon.js");

const FIXTURES = [
  {
    name: "refresh-icon-ready",
    ticket: {
      repo: "local/loupe",
      number: 1,
      title: "Add refresh icon to inbox refresh button",
      body: "Need a small icon in the inbox refresh button.",
      labels: ["ui"]
    },
    raw: {
      outcome: "ready",
      summary: "Add an icon affordance to the inbox refresh button.",
      size: "S",
      files: [{ path: "index.html", is_new: false, confidence: 0.91, why: "The refresh button markup lives in the PWA shell." }],
      deps: [],
      migrations: [],
      risk_areas: [],
      out_of_scope: [],
      open_questions: [],
      default_agent: "codex",
      blueprint_confidence: 0.82
    },
    expected: {
      outcome: "ready",
      filesMustInclude: ["index.html"]
    }
  },
  {
    name: "bug-needs-info",
    ticket: {
      repo: "local/loupe",
      number: 2,
      title: "Fix the login bug",
      body: "Login is broken.",
      labels: ["bug"]
    },
    raw: {
      outcome: "needs_info",
      missing_info: ["Reproduction steps", "Expected vs actual behavior"],
      summary: "Ticket needs reproduction details before dispatch."
    },
    expected: {
      outcome: "needs_info",
      missingInfoMin: 1
    }
  },
  {
    name: "deviation-uses-actual-diff",
    ticket: {
      repo: "local/loupe",
      number: 3,
      title: "Persist Blueprint cache",
      body: "Cache Blueprint output per ticket and HEAD."
    },
    raw: {
      outcome: "ready",
      summary: "Cache Blueprint output by ticket hash and repository HEAD.",
      size: "M",
      files: [{ path: "daemon.js", is_new: false, confidence: 0.9, why: "Cache layer lives in the daemon." }],
      deps: [],
      migrations: [],
      risk_areas: ["performance"],
      out_of_scope: [],
      open_questions: [],
      default_agent: "claude",
      blueprint_confidence: 0.74
    },
    changedFiles: ["daemon.js", "index.html"],
    expected: {
      outcome: "ready",
      filesMustInclude: ["daemon.js"],
      unpredictedFiles: ["index.html"]
    }
  }
];

function scoreFixture(fixture, blueprint) {
  const failures = [];
  if (blueprint.outcome !== fixture.expected.outcome) {
    failures.push(`expected outcome ${fixture.expected.outcome}, got ${blueprint.outcome}`);
  }
  for (const file of fixture.expected.filesMustInclude || []) {
    if (!blueprint.files.some((item) => item.path === file)) {
      failures.push(`missing predicted file ${file}`);
    }
  }
  if (fixture.expected.missingInfoMin && blueprint.missingInfo.length < fixture.expected.missingInfoMin) {
    failures.push(`expected at least ${fixture.expected.missingInfoMin} missing_info item`);
  }
  if (fixture.expected.unpredictedFiles) {
    const deviation = compareBlueprintHandoff(blueprint, fixture.changedFiles || [], { confidence: 0.5, files_changed: fixture.changedFiles || [] });
    for (const file of fixture.expected.unpredictedFiles) {
      if (!deviation.filesTouchedNotPredicted.includes(file)) {
        failures.push(`expected ${file} to be flagged as unpredicted`);
      }
    }
  }
  return failures;
}

async function run() {
  const live = process.argv.includes("--live");
  const workspace = { id: "workspace-eval", name: "Dash", path: __dirname };
  const results = [];

  for (const fixture of FIXTURES) {
    const blueprint = live
      ? await createBlueprint(fixture.ticket, workspace.id, null, { bypassCache: true })
      : validateBlueprint(normalizeBlueprint(fixture.raw, fixture.ticket, workspace, "fixture"));
    const failures = scoreFixture(fixture, blueprint);
    results.push({ name: fixture.name, ok: failures.length === 0, failures });
  }

  const passed = results.filter((result) => result.ok).length;
  for (const result of results) {
    console.log(`${result.ok ? "PASS" : "FAIL"} ${result.name}`);
    for (const failure of result.failures) console.log(`  - ${failure}`);
  }
  console.log(`\n${passed}/${results.length} fixtures passed`);
  if (passed !== results.length) process.exitCode = 1;
}

run().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
