// Unit tests for the security hardening. No external deps — uses node:test.
// Run: node --test scripts/test-hardening.js   (or: node scripts/test-hardening.js)
const test = require("node:test");
const assert = require("node:assert/strict");
const os = require("os");
const fs = require("fs");
const path = require("path");

const security = require("../daemon/security");
const { createConfigManager } = require("../daemon/config");

// --- isSsePath --------------------------------------------------------------
test("isSsePath only matches read-only stream endpoints", () => {
  assert.equal(security.isSsePath("/api/v1/inbox/stream"), true);
  assert.equal(security.isSsePath("/api/sessions/events/abc-123"), true);
  assert.equal(security.isSsePath("/api/codex/events/xyz"), true);
  assert.equal(security.isSsePath("/api/sessions/start"), false);
  assert.equal(security.isSsePath("/api/v1/prs/o/r/3/merge"), false);
  assert.equal(security.isSsePath("/api/inbox/stream/../start"), false);
});

// --- isAllowedStatic --------------------------------------------------------
test("isAllowedStatic serves only the PWA asset surface", () => {
  for (const ok of ["index.html", "manifest.webmanifest", "sw.js", "icons/app-icon.svg", "icons/jira/issuetype/bug.svg"]) {
    assert.equal(security.isAllowedStatic(ok), true, `${ok} should be allowed`);
  }
  for (const bad of ["daemon.js", "PRD.md", "blueprint.prompt.md", ".loupe-workspaces.json", "daemon/config.js", "iconsX/secret"]) {
    assert.equal(security.isAllowedStatic(bad), false, `${bad} should be denied`);
  }
});

// --- flagSensitiveChanges ---------------------------------------------------
test("flagSensitiveChanges catches host-executed files", () => {
  const flagged = security.flagSensitiveChanges([
    "src/index.ts",
    ".github/workflows/ci.yml",
    "package.json",
    "scripts/build.sh",
    ".husky/pre-commit",
    "Makefile",
    "README.md",
  ]);
  const paths = flagged.map((f) => f.path);
  assert.deepEqual(paths.sort(), [".github/workflows/ci.yml", ".husky/pre-commit", "Makefile", "package.json"].sort());
  assert.ok(flagged.every((f) => typeof f.reason === "string" && f.reason.length));
});

test("flagSensitiveChanges returns empty for ordinary source changes", () => {
  assert.deepEqual(security.flagSensitiveChanges(["src/a.ts", "lib/b.py", "docs/c.md"]), []);
  assert.deepEqual(security.flagSensitiveChanges([]), []);
  assert.deepEqual(security.flagSensitiveChanges(undefined), []);
});

// --- injection guard --------------------------------------------------------
test("INJECTION_GUARD frames third-party text as data, not instructions", () => {
  assert.match(security.INJECTION_GUARD, /not as instructions/i);
  assert.match(security.INJECTION_GUARD, /do not comply/i);
});

// --- auth throttle ----------------------------------------------------------
test("createAuthThrottle locks out after max failures and clears on success", () => {
  let clock = 1_000_000;
  const locks = [];
  const t = security.createAuthThrottle({ max: 3, windowMs: 60_000, lockMs: 10_000, now: () => clock, onLock: (ip) => locks.push(ip) });

  assert.equal(t.lockState("1.2.3.4").locked, false);
  t.recordFailure("1.2.3.4");
  t.recordFailure("1.2.3.4");
  assert.equal(t.lockState("1.2.3.4").locked, false, "below threshold not locked");
  t.recordFailure("1.2.3.4"); // 3rd → lock
  const locked = t.lockState("1.2.3.4");
  assert.equal(locked.locked, true);
  assert.ok(locked.retryAfterMs > 0 && locked.retryAfterMs <= 10_000);
  assert.deepEqual(locks, ["1.2.3.4"]);

  // A different IP is unaffected.
  assert.equal(t.lockState("9.9.9.9").locked, false);

  // Lock expires after lockMs.
  clock += 10_001;
  assert.equal(t.lockState("1.2.3.4").locked, false, "lock expired");

  // Success clears the counter.
  t.recordFailure("5.5.5.5");
  t.clearFailures("5.5.5.5");
  assert.equal(t.lockState("5.5.5.5").locked, false);
});

test("createAuthThrottle resets the count after the window elapses", () => {
  let clock = 0;
  const t = security.createAuthThrottle({ max: 2, windowMs: 1_000, lockMs: 5_000, now: () => clock });
  t.recordFailure("ip"); // count 1
  clock += 2_000;        // window elapsed
  t.recordFailure("ip"); // count resets to 1, not 2 → no lock
  assert.equal(t.lockState("ip").locked, false);
});

// --- config: token transport + constant-time compare ------------------------
function tmpConfigManager(apiToken) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "loupe-cfg-"));
  const file = path.join(dir, "config.json");
  const mgr = createConfigManager({ loupeHome: dir, configFile: file, githubOAuthClientId: "" });
  mgr.config.apiToken = apiToken;
  return mgr;
}

const fakeIp = () => "127.0.0.1";

test("query-string token is rejected unless explicitly allowed (SSE only)", () => {
  const mgr = tmpConfigManager("secret-token");
  const url = new URL("http://x/api/sessions/start?token=secret-token");
  const req = { headers: {}, socket: { remoteAddress: "127.0.0.1" } };

  // Default (mutating endpoint): query token must NOT authorize.
  assert.equal(mgr.isAuthorized(req, url, fakeIp), false);
  // SSE path opts in: query token authorizes.
  assert.equal(mgr.isAuthorized(req, url, fakeIp, { allowQueryToken: true }), true);
});

test("header token authorizes any endpoint; wrong token never does", () => {
  const mgr = tmpConfigManager("secret-token");
  const url = new URL("http://x/api/sessions/start");
  const good = { headers: { "x-loupe-token": "secret-token" }, socket: { remoteAddress: "127.0.0.1" } };
  const bearer = { headers: { authorization: "Bearer secret-token" }, socket: { remoteAddress: "127.0.0.1" } };
  const bad = { headers: { "x-loupe-token": "nope" }, socket: { remoteAddress: "127.0.0.1" } };

  assert.equal(mgr.isAuthorized(good, url, fakeIp), true);
  assert.equal(mgr.isAuthorized(bearer, url, fakeIp), true);
  assert.equal(mgr.isAuthorized(bad, url, fakeIp), false);
  assert.equal(mgr.isAuthorized({ headers: {}, socket: {} }, url, fakeIp), false);
});

test("requestAuthToken ignores query token by default, reads it when allowed", () => {
  const mgr = tmpConfigManager("t");
  const url = new URL("http://x/api/v1/inbox/stream?token=streamtok");
  const req = { headers: {} };
  assert.equal(mgr.requestAuthToken(req, url), "");
  assert.equal(mgr.requestAuthToken(req, url, { allowQueryToken: true }), "streamtok");
});
