const http = require("http");
const https = require("https");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const HOST = "0.0.0.0";
const PORT = Number(process.env.PORT || 4173);
const ROOT = __dirname;
const CODEX_BIN = process.env.CODEX_BIN || "/Applications/Codex.app/Contents/Resources/codex";
const CLAUDE_BIN = process.env.CLAUDE_BIN || findClaudeBin();
const WORKSPACE_STORE = path.join(ROOT, ".loupe-workspaces.json");
const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const CODEX_SESSIONS_DIR = path.join(CODEX_HOME, "sessions");
const CLAUDE_HOME = process.env.CLAUDE_HOME || path.join(os.homedir(), ".claude");
const CLAUDE_PROJECTS_DIR = path.join(CLAUDE_HOME, "projects");
const LOUPE_HOME = process.env.LOUPE_HOME || path.join(os.homedir(), ".loupe");
const CONFIG_FILE = path.join(LOUPE_HOME, "config.json");
const STATE_FILE = path.join(LOUPE_HOME, "state.json");
const BLUEPRINT_PROMPT_FILE = path.join(ROOT, "blueprint.prompt.md");
const BLUEPRINT_SCHEMA_FILE = path.join(ROOT, "blueprint.schema.json");
const BLUEPRINT_CACHE_DIR = path.join(LOUPE_HOME, "blueprints");
const GITHUB_OAUTH_CLIENT_ID = process.env.GITHUB_OAUTH_CLIENT_ID || "";
const GITHUB_OAUTH_SCOPES = process.env.GITHUB_OAUTH_SCOPES || "repo read:user";

const sessions = new Map();
const plans = new Map();
const recentRequests = [];
const workspaces = getConfiguredWorkspaces();
const harnessRegistry = buildHarnessRegistry();
let config = loadConfig();
ensureAlphaAuth();
// Cache the GitHub inbox briefly so the PWA can re-render without hammering the API.
const inboxCache = { fetchedAt: 0, ttlMs: 60_000, payload: null };
const githubOAuthFlows = new Map();
const blueprintJobs = new Map();
const blueprintQueue = [];
let activeBlueprintJobs = 0;
const MAX_BACKGROUND_BLUEPRINT_JOBS = Number(process.env.LOUPE_BLUEPRINT_CONCURRENCY || 1);

function findClaudeBin() {
  // 1. claude on PATH
  const which = spawnSync("which", ["claude"], { timeout: 1500 });
  if (which.status === 0) {
    const trimmed = which.stdout.toString().trim();
    if (trimmed) return trimmed;
  }
  // 2. Claude Desktop's embedded CLI (latest version)
  const desktopDir = path.join(os.homedir(), "Library/Application Support/Claude/claude-code");
  try {
    const versions = fs.readdirSync(desktopDir)
      .filter((v) => {
        try {
          return fs.statSync(path.join(desktopDir, v, "claude.app/Contents/MacOS/claude")).isFile();
        } catch { return false; }
      })
      .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
    if (versions.length) {
      return path.join(desktopDir, versions[0], "claude.app/Contents/MacOS/claude");
    }
  } catch {}
  return null;
}

function detectBin(bin) {
  if (!bin) return { available: false };
  if (!fs.existsSync(bin)) return { available: false, bin };
  try {
    const result = spawnSync(bin, ["--version"], { timeout: 4000, killSignal: "SIGKILL" });
    if (result.status === 0) {
      const version = (result.stdout?.toString() || result.stderr?.toString() || "").trim().split(/\r?\n/)[0];
      return { available: true, bin, version };
    }
  } catch {}
  return { available: false, bin };
}

function buildHarnessRegistry() {
  return [
    { id: "codex", label: "codex", ...detectBin(CODEX_BIN) },
    { id: "claude-code", label: "claude code", ...detectBin(CLAUDE_BIN) }
  ];
}

function getHarness(id) {
  return harnessRegistry.find((h) => h.id === id);
}

function defaultHarnessId() {
  const codex = getHarness("codex");
  if (codex?.available) return "codex";
  const claude = getHarness("claude-code");
  if (claude?.available) return "claude-code";
  return "codex";
}

// ---------- Config ----------
// ~/.loupe/config.json holds BYOK credentials. Token never leaves the daemon
// process; the PWA only learns whether one is configured.

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
  } catch {
    return {};
  }
}

function saveConfig() {
  fs.mkdirSync(LOUPE_HOME, { recursive: true });
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
  // Restrict to user-only — these are secrets.
  try { fs.chmodSync(CONFIG_FILE, 0o600); } catch {}
}

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
    deviation: session.deviation || null
  };
}

function persistState() {
  try {
    fs.mkdirSync(LOUPE_HOME, { recursive: true });
    const payload = {
      version: 1,
      savedAt: new Date().toISOString(),
      sessions: [...sessions.values()].map(serializeSession).slice(-100),
      plans: [...plans.values()].slice(-200)
    };
    const tmp = `${STATE_FILE}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(payload, null, 2));
    fs.renameSync(tmp, STATE_FILE);
    try { fs.chmodSync(STATE_FILE, 0o600); } catch {}
  } catch (error) {
    console.warn(`Could not persist Loupe state: ${error.message}`);
  }
}

function hydrateState() {
  let payload = null;
  try {
    payload = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
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

function createSecretToken() {
  return crypto.randomBytes(32).toString("base64url");
}

function hashToken(token) {
  return crypto.createHash("sha256").update(String(token || "")).digest("hex");
}

function ensureDeviceRegistry() {
  if (!Array.isArray(config.devices)) config.devices = [];
  if (config.apiToken && !config.devices.some((device) => device.tokenHash === hashToken(config.apiToken))) {
    config.devices.push({
      id: `device-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
      name: "Paired browser",
      tokenHash: hashToken(config.apiToken),
      createdAt: new Date().toISOString(),
      lastSeenAt: null,
      lastIp: null,
      revokedAt: null
    });
    saveConfig();
  }
}

function ensureAlphaAuth() {
  if (!config.apiToken) {
    config.apiToken = createSecretToken();
    saveConfig();
  }
  ensureDeviceRegistry();
}

function tokenPreview(token) {
  if (!token) return null;
  return `${token.slice(0, 6)}...${token.slice(-4)}`;
}

function configSummary() {
  const githubAuth = config.github || {};
  return {
    auth: {
      enabled: true,
      tokenPreview: tokenPreview(config.apiToken)
    },
    github: {
      configured: !!getGithubAccessToken(),
      login: githubAuth.login || config.githubLogin || null,
      avatarUrl: githubAuth.avatarUrl || null,
      authType: githubAuth.accessToken ? "oauth" : config.githubToken ? "pat" : null,
      oauthClientConfigured: !!GITHUB_OAUTH_CLIENT_ID
    },
    devices: (config.devices || []).filter((device) => !device.revokedAt).map((device) => ({
      id: device.id,
      name: device.name,
      createdAt: device.createdAt,
      lastSeenAt: device.lastSeenAt,
      lastIp: device.lastIp
    }))
  };
}

// ---------- Git ----------
// Parse each workspace's origin remote to bind it to a GitHub repo. Cheap
// enough to do on every inbox refresh; no caching.

function workspaceRepoBinding(workspace) {
  try {
    const result = spawnSync("git", ["-C", workspace.path, "remote", "get-url", "origin"], { timeout: 1500 });
    if (result.status !== 0) return null;
    const url = result.stdout.toString().trim();
    return parseGithubRemote(url);
  } catch {
    return null;
  }
}

function parseGithubRemote(remote) {
  if (!remote) return null;
  // Handle ssh (git@github.com:owner/repo.git) and https (https://github.com/owner/repo.git)
  const ssh = remote.match(/^git@github\.com:([^/]+)\/(.+?)(?:\.git)?$/i);
  if (ssh) return { host: "github.com", owner: ssh[1], repo: ssh[2] };
  const https = remote.match(/^https?:\/\/(?:[^@]+@)?github\.com\/([^/]+)\/(.+?)(?:\.git)?\/?$/i);
  if (https) return { host: "github.com", owner: https[1], repo: https[2] };
  return null;
}

function listWorkspaceBindings() {
  return workspaces
    .map((workspace) => {
      const binding = workspaceRepoBinding(workspace);
      return binding ? { workspaceId: workspace.id, workspacePath: workspace.path, ...binding } : null;
    })
    .filter(Boolean);
}

function repoHeadSha(workspace) {
  try {
    const result = spawnSync("git", ["-C", workspace.path, "rev-parse", "HEAD"], { timeout: 1500, encoding: "utf8" });
    if (result.status === 0) return result.stdout.trim();
  } catch {}
  return "no-git-head";
}

function workspaceReadiness(workspace) {
  const blockers = [];
  const warnings = [];
  const pathExists = fs.existsSync(workspace.path);
  let isGitRepo = false;
  let branch = null;
  let dirty = false;
  let binding = null;

  if (!pathExists) {
    blockers.push("Workspace folder no longer exists.");
  } else {
    const inside = spawnSync("git", ["-C", workspace.path, "rev-parse", "--is-inside-work-tree"], { timeout: 1500, encoding: "utf8" });
    isGitRepo = inside.status === 0 && inside.stdout.trim() === "true";
    if (!isGitRepo) {
      blockers.push("Workspace is not a git repository.");
    } else {
      binding = workspaceRepoBinding(workspace);
      if (!binding) blockers.push("Workspace is not bound to a GitHub remote.");

      const head = spawnSync("git", ["-C", workspace.path, "rev-parse", "--abbrev-ref", "HEAD"], { timeout: 1500, encoding: "utf8" });
      if (head.status === 0) branch = head.stdout.trim();
      else warnings.push("Could not read current branch.");

      const status = spawnSync("git", ["-C", workspace.path, "status", "--porcelain"], { timeout: 2000, encoding: "utf8" });
      if (status.status === 0) {
        dirty = !!status.stdout.trim();
        if (dirty) blockers.push("Workspace has uncommitted changes.");
      } else {
        blockers.push("Could not read git status.");
      }
    }
  }

  if (!getGithubAccessToken()) {
    warnings.push("GitHub is not connected; Loupe can push with git credentials but cannot create draft PRs via API.");
  }

  return {
    workspaceId: workspace.id,
    workspacePath: workspace.path,
    ready: blockers.length === 0,
    canDispatch: blockers.length === 0,
    pathExists,
    isGitRepo,
    branch,
    dirty,
    binding,
    blockers,
    warnings
  };
}

function listWorkspaceReadiness() {
  return workspaces.map(workspaceReadiness);
}

// ---------- GitHub API ----------
// Minimal HTTPS-only client. Uses search/issues so we can scope to assignee:@me
// across every repo the token can see in one call, then enriches with PR review
// requests in a second call. Enough for the demo inbox.

function getGithubAccessToken() {
  return config.github?.accessToken || config.githubToken || "";
}

function saveGithubOAuth(tokenPayload, viewer) {
  config.github = {
    accessToken: tokenPayload.access_token,
    tokenType: tokenPayload.token_type || "bearer",
    scope: tokenPayload.scope || GITHUB_OAUTH_SCOPES,
    login: viewer?.login || null,
    avatarUrl: viewer?.avatar_url || null,
    connectedAt: new Date().toISOString()
  };
  delete config.githubToken;
  delete config.githubLogin;
  saveConfig();
  inboxCache.fetchedAt = 0;
  inboxCache.payload = null;
}

function clearGithubAuth() {
  delete config.github;
  delete config.githubToken;
  delete config.githubLogin;
  saveConfig();
  inboxCache.fetchedAt = 0;
  inboxCache.payload = null;
}

function githubRequest(pathname, token) {
  return githubApiRequest("GET", pathname, token);
}

function githubApiRequest(method, pathname, token, payload = null) {
  const body = payload ? JSON.stringify(payload) : "";
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: "api.github.com",
      path: pathname,
      method,
      headers: {
        "user-agent": "loupe-mac-daemon",
        accept: "application/vnd.github+json",
        "x-github-api-version": "2022-11-28",
        authorization: `Bearer ${token}`,
        ...(body ? { "content-type": "application/json", "content-length": Buffer.byteLength(body) } : {})
      }
    }, (res) => {
      let body = "";
      res.on("data", (chunk) => { body += chunk; });
      res.on("end", () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try { resolve(JSON.parse(body)); } catch (error) { reject(error); }
        } else {
          const err = new Error(`GitHub ${res.statusCode}: ${body.slice(0, 300)}`);
          err.statusCode = res.statusCode;
          reject(err);
        }
      });
    });
    req.on("error", reject);
    req.setTimeout(15_000, () => req.destroy(new Error("GitHub request timeout")));
    if (body) req.write(body);
    req.end();
  });
}

function githubOAuthPost(pathname, params) {
  const body = new URLSearchParams(params).toString();
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: "github.com",
      path: pathname,
      method: "POST",
      headers: {
        "user-agent": "loupe-mac-daemon",
        accept: "application/json",
        "content-type": "application/x-www-form-urlencoded",
        "content-length": Buffer.byteLength(body)
      }
    }, (res) => {
      let responseBody = "";
      res.on("data", (chunk) => { responseBody += chunk; });
      res.on("end", () => {
        let parsed = {};
        try { parsed = JSON.parse(responseBody); } catch {
          const query = new URLSearchParams(responseBody);
          parsed = Object.fromEntries(query.entries());
        }
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(parsed);
        } else {
          const err = new Error(parsed.error_description || parsed.error || `GitHub OAuth ${res.statusCode}`);
          err.statusCode = res.statusCode;
          err.payload = parsed;
          reject(err);
        }
      });
    });
    req.on("error", reject);
    req.setTimeout(15_000, () => req.destroy(new Error("GitHub OAuth request timeout")));
    req.write(body);
    req.end();
  });
}

function cleanupGithubOAuthFlows() {
  const now = Date.now();
  for (const [id, flow] of githubOAuthFlows) {
    if (flow.expiresAt <= now) githubOAuthFlows.delete(id);
  }
}

async function fetchGithubInbox(token) {
  // Two queries, one assignee one review-requested. Search API supports both.
  const [assignedIssues, reviewRequests, viewer] = await Promise.all([
    githubRequest(`/search/issues?q=${encodeURIComponent("assignee:@me is:open archived:false")}&per_page=30&sort=updated`, token),
    githubRequest(`/search/issues?q=${encodeURIComponent("is:pr is:open review-requested:@me archived:false")}&per_page=30&sort=updated`, token),
    githubRequest("/user", token)
  ]);

  // Persist login on first fetch so we can show it in config summary.
  if (viewer?.login && config.github?.accessToken && config.github.login !== viewer.login) {
    config.github.login = viewer.login;
    config.github.avatarUrl = viewer.avatar_url || config.github.avatarUrl || null;
    saveConfig();
  } else if (viewer?.login && config.githubLogin !== viewer.login) {
    config.githubLogin = viewer.login;
    saveConfig();
  }

  const bindings = listWorkspaceBindings();
  function bindingFor(repoFullName) {
    if (!repoFullName) return null;
    const [owner, repo] = repoFullName.split("/");
    const matches = bindings.filter((b) => b.owner.toLowerCase() === owner.toLowerCase() && b.repo.toLowerCase() === repo.toLowerCase());
    return matches.find((b) => {
      const workspace = workspaces.find((w) => w.id === b.workspaceId);
      return workspace && workspaceReadiness(workspace).canDispatch;
    }) || matches[0] || null;
  }

  function normalize(item, kind) {
    // search/issues returns issues and PRs together; pull_request is non-null for PRs.
    const repoFullName = (item.repository_url || "").replace("https://api.github.com/repos/", "");
    const binding = bindingFor(repoFullName);
    const workspace = binding ? workspaces.find((w) => w.id === binding.workspaceId) : null;
    const ticket = {
      kind, // "issue" or "review"
      id: item.id,
      number: item.number,
      title: item.title,
      body: (item.body || "").slice(0, 4000),
      url: item.html_url,
      state: item.state,
      isPr: !!item.pull_request,
      labels: (item.labels || []).map((l) => l.name),
      repo: repoFullName,
      updatedAt: item.updated_at,
      createdAt: item.created_at,
      author: item.user?.login || null,
      binding,
      blueprint: null
    };
    if (kind === "issue" && workspace) {
      // Generate ONCE, on first sight. Never auto-regenerate. If the files this
      // Blueprint references change later, surface a stale badge and let the user
      // decide to refresh — generation is expensive and should be deliberate.
      const cached = readCachedBlueprintForTicket(ticket, workspace);
      if (cached) {
        annotateStaleness(cached, workspace);
        ticket.blueprint = cached;
      } else {
        ticket.blueprint = enqueueBlueprintForTicket(ticket, workspace);
      }
    }
    return ticket;
  }

  const assigned = (assignedIssues.items || []).map((item) => normalize(item, "issue"));
  const reviews = (reviewRequests.items || []).map((item) => normalize(item, "review"));

  return {
    fetchedAt: new Date().toISOString(),
    viewer: { login: viewer?.login, avatarUrl: viewer?.avatar_url },
    assigned,
    reviews
  };
}

function normalizeIssuePayload(issue, repoFullName) {
  return {
    kind: "issue",
    id: issue.id,
    number: issue.number,
    title: issue.title,
    body: (issue.body || "").slice(0, 4000),
    url: issue.html_url,
    state: issue.state,
    isPr: false,
    labels: (issue.labels || []).map((l) => l.name),
    repo: repoFullName,
    updatedAt: issue.updated_at,
    createdAt: issue.created_at,
    author: issue.user?.login || null,
    binding: null,
    blueprint: null
  };
}

async function createGithubIssue({ repoFullName, title, body = "", assignSelf = true }) {
  const token = getGithubAccessToken();
  if (!token) {
    const err = new Error("GitHub is not connected. Connect GitHub with OAuth first.");
    err.statusCode = 400;
    throw err;
  }

  const bindings = listWorkspaceBindings();
  const binding = bindings.find((item) => `${item.owner}/${item.repo}`.toLowerCase() === String(repoFullName || "").toLowerCase());
  if (!binding) {
    const err = new Error("Choose a GitHub repo that is bound to one of your Loupe workspaces.");
    err.statusCode = 400;
    throw err;
  }

  const cleanTitle = String(title || "").trim();
  if (!cleanTitle) {
    const err = new Error("Issue title is required.");
    err.statusCode = 400;
    throw err;
  }

  const viewerLogin = config.github?.login || config.githubLogin || null;
  const payload = {
    title: cleanTitle.slice(0, 256),
    body: String(body || "").trim()
  };
  if (assignSelf && viewerLogin) payload.assignees = [viewerLogin];

  const owner = encodeURIComponent(binding.owner);
  const repo = encodeURIComponent(binding.repo);
  const issue = await githubApiRequest("POST", `/repos/${owner}/${repo}/issues`, token, payload);
  inboxCache.fetchedAt = 0;
  inboxCache.payload = null;

  const normalized = normalizeIssuePayload(issue, `${binding.owner}/${binding.repo}`);
  normalized.binding = binding;
  return normalized;
}

function parseRepoPair(owner, repo) {
  const cleanOwner = String(owner || "").trim();
  const cleanRepo = String(repo || "").trim();
  if (!/^[A-Za-z0-9_.-]+$/.test(cleanOwner) || !/^[A-Za-z0-9_.-]+$/.test(cleanRepo)) {
    const error = new Error("Invalid GitHub repository.");
    error.statusCode = 400;
    throw error;
  }
  return { owner: cleanOwner, repo: cleanRepo };
}

function findSessionForPr({ owner, repo, number, branch }) {
  const repoFullName = `${owner}/${repo}`;
  const candidates = [...sessions.values()].reverse();
  return candidates.find((session) => {
    if (branch && session.branch?.name === branch && session.branch?.repo === repoFullName) return true;
    return (session.events || []).some((event) =>
      event.type === "branch" &&
      event.kind === "pr_ready" &&
      event.prNumber === number &&
      event.repo === repoFullName
    );
  }) || null;
}

function parsePrHandoff(body) {
  const text = String(body || "");
  const section = (title) => {
    const pattern = new RegExp(`## ${title}\\n([\\s\\S]*?)(?=\\n## |\\n---|$)`, "i");
    return (text.match(pattern)?.[1] || "").trim();
  };
  const list = (value) => value
    .split(/\r?\n/)
    .map((line) => line.replace(/^[-*]\s*/, "").trim())
    .filter((line) => line && !/^_none/i.test(line));
  const confidenceText = section("Confidence");
  return {
    tldr: section("What I did"),
    why: section("Why"),
    approach: section("Approach"),
    files_changed: list(section("Files changed(?: \\([^)]*\\))?")),
    verify: list(section("I want you to double-check")),
    tests_run: list(section("Verified")),
    tests_not_run: list(section("Not verified")),
    confidence: confidenceText ? Number(confidenceText.replace(/[^0-9.]/g, "")) / 100 : null
  };
}

function normalizeCheckState({ pr, combinedStatus, checkRuns }) {
  const states = [];
  if (combinedStatus?.state) states.push(combinedStatus.state);
  for (const run of checkRuns?.check_runs || []) {
    states.push(run.conclusion || run.status);
  }
  if (!states.length) return "unknown";
  if (states.some((state) => ["failure", "error", "cancelled", "timed_out", "action_required"].includes(state))) return "failing";
  if (states.some((state) => ["pending", "queued", "in_progress", "waiting", "requested"].includes(state))) return "pending";
  if (states.every((state) => ["success", "neutral", "skipped", "completed"].includes(state))) return "passing";
  return pr.mergeable_state || "unknown";
}

async function fetchPullRequestDetail(owner, repo, number) {
  const token = getGithubAccessToken();
  if (!token) {
    const error = new Error("GitHub is not connected.");
    error.statusCode = 401;
    throw error;
  }
  const safe = parseRepoPair(owner, repo);
  const prNumber = Number(number);
  if (!Number.isInteger(prNumber) || prNumber <= 0) {
    const error = new Error("Invalid pull request number.");
    error.statusCode = 400;
    throw error;
  }
  const repoPath = `/repos/${encodeURIComponent(safe.owner)}/${encodeURIComponent(safe.repo)}`;
  const [pr, files, reviews] = await Promise.all([
    githubApiRequest("GET", `${repoPath}/pulls/${prNumber}`, token),
    githubApiRequest("GET", `${repoPath}/pulls/${prNumber}/files?per_page=100`, token),
    githubApiRequest("GET", `${repoPath}/pulls/${prNumber}/reviews?per_page=50`, token)
  ]);
  const [combinedStatus, checkRuns] = await Promise.all([
    githubApiRequest("GET", `${repoPath}/commits/${encodeURIComponent(pr.head.sha)}/status`, token).catch(() => null),
    githubApiRequest("GET", `${repoPath}/commits/${encodeURIComponent(pr.head.sha)}/check-runs?per_page=50`, token).catch(() => null)
  ]);
  const session = findSessionForPr({ owner: safe.owner, repo: safe.repo, number: prNumber, branch: pr.head.ref });
  const handoff = session?.handoff || parsePrHandoff(pr.body || "");
  return {
    repo: `${safe.owner}/${safe.repo}`,
    owner: safe.owner,
    repoName: safe.repo,
    number: pr.number,
    title: pr.title,
    body: pr.body || "",
    url: pr.html_url,
    state: pr.state,
    draft: !!pr.draft,
    merged: !!pr.merged,
    mergeable: pr.mergeable,
    mergeableState: pr.mergeable_state || null,
    author: pr.user?.login || null,
    base: { ref: pr.base.ref, sha: pr.base.sha },
    head: { ref: pr.head.ref, sha: pr.head.sha },
    additions: pr.additions,
    deletions: pr.deletions,
    changedFiles: pr.changed_files,
    checkState: normalizeCheckState({ pr, combinedStatus, checkRuns }),
    checks: {
      combinedState: combinedStatus?.state || null,
      runs: (checkRuns?.check_runs || []).map((run) => ({
        id: run.id,
        name: run.name,
        status: run.status,
        conclusion: run.conclusion,
        url: run.html_url
      }))
    },
    files: (files || []).map((file) => ({
      filename: file.filename,
      status: file.status,
      additions: file.additions,
      deletions: file.deletions,
      changes: file.changes,
      patch: file.patch || "",
      blobUrl: file.blob_url
    })),
    reviews: (reviews || []).map((review) => ({
      id: review.id,
      user: review.user?.login || null,
      state: review.state,
      body: review.body || "",
      submittedAt: review.submitted_at,
      url: review.html_url
    })),
    loupe: {
      sessionId: session?.id || null,
      harness: session?.harnessId || null,
      handoff,
      deviation: session?.deviation || null
    }
  };
}

async function submitPullRequestReview(owner, repo, number, { event, body }) {
  const token = getGithubAccessToken();
  if (!token) {
    const error = new Error("GitHub is not connected.");
    error.statusCode = 401;
    throw error;
  }
  const safe = parseRepoPair(owner, repo);
  return githubApiRequest("POST", `/repos/${encodeURIComponent(safe.owner)}/${encodeURIComponent(safe.repo)}/pulls/${Number(number)}/reviews`, token, {
    event,
    body: body || ""
  });
}

async function mergePullRequest(owner, repo, number, { commitTitle, commitMessage } = {}) {
  const token = getGithubAccessToken();
  if (!token) {
    const error = new Error("GitHub is not connected.");
    error.statusCode = 401;
    throw error;
  }
  const safe = parseRepoPair(owner, repo);
  return githubApiRequest("PUT", `/repos/${encodeURIComponent(safe.owner)}/${encodeURIComponent(safe.repo)}/pulls/${Number(number)}/merge`, token, {
    merge_method: "squash",
    ...(commitTitle ? { commit_title: commitTitle } : {}),
    ...(commitMessage ? { commit_message: commitMessage } : {})
  });
}

async function closePullRequest(owner, repo, number) {
  const token = getGithubAccessToken();
  if (!token) {
    const error = new Error("GitHub is not connected.");
    error.statusCode = 401;
    throw error;
  }
  const safe = parseRepoPair(owner, repo);
  return githubApiRequest("PATCH", `/repos/${encodeURIComponent(safe.owner)}/${encodeURIComponent(safe.repo)}/pulls/${Number(number)}`, token, {
    state: "closed"
  });
}

const mimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".md": "text/markdown; charset=utf-8"
};

// Public URL from a Cloudflare quick tunnel, when one is running. Lets the
// phone pair from any network. Null until the tunnel is up (or if disabled).
let tunnelUrl = null;

function getNetworkUrls() {
  const interfaces = os.networkInterfaces();
  const urls = [];

  // A public tunnel URL is the most useful first entry when present.
  if (tunnelUrl) urls.push(`${tunnelUrl}/index.html`);

  urls.push(`http://localhost:${PORT}/index.html`);

  for (const entries of Object.values(interfaces)) {
    for (const entry of entries || []) {
      if (entry.family === "IPv4" && !entry.internal) {
        urls.push(`http://${entry.address}:${PORT}/index.html`);
      }
    }
  }

  return urls;
}

function getPairingUrls() {
  return getNetworkUrls().map((url) => `${url}?pair=${encodeURIComponent(config.apiToken)}`);
}

// The single best pairing URL to encode in the QR: tunnel if present, else LAN.
function getPrimaryPairingUrl() {
  const urls = getPairingUrls();
  return urls.find((u) => u.startsWith("https://")) || urls.find((u) => !u.includes("localhost")) || urls[0];
}

// Start a Cloudflare quick tunnel via the `cloudflared` binary. Additive and
// optional: enabled with LOUPE_TUNNEL=1. No-op (logs a hint) if cloudflared is
// not installed. Does NOT change the auth model — the same pair token is used.
function startTunnel() {
  if (process.env.LOUPE_TUNNEL !== "1") return;
  const probe = spawnSync("cloudflared", ["--version"], { encoding: "utf8" });
  if (probe.status !== 0) {
    console.log("LOUPE_TUNNEL=1 set but `cloudflared` is not installed.");
    console.log("  Install with: brew install cloudflared");
    return;
  }
  const child = spawn("cloudflared", ["tunnel", "--url", `http://localhost:${PORT}`], {
    stdio: ["ignore", "pipe", "pipe"]
  });
  const onData = (buf) => {
    const text = buf.toString();
    const match = text.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/i);
    if (match && !tunnelUrl) {
      tunnelUrl = match[0];
      console.log(`\nPublic tunnel ready: ${tunnelUrl}`);
      console.log("Scan to pair from any network:");
      renderQr(getPrimaryPairingUrl());
    }
  };
  child.stdout.on("data", onData);
  child.stderr.on("data", onData); // cloudflared logs the URL to stderr
  child.on("exit", (code) => {
    console.log(`cloudflared tunnel exited (code ${code}). Pairing falls back to LAN.`);
    tunnelUrl = null;
  });
  process.on("exit", () => child.kill());
}

// Render a QR code in the terminal. Uses the `qrencode` CLI if available
// (brew install qrencode); otherwise prints the URL to copy/paste.
function renderQr(text) {
  const q = spawnSync("qrencode", ["-t", "ANSIUTF8", "-m", "1", text], { encoding: "utf8" });
  if (q.status === 0 && q.stdout) {
    console.log(q.stdout);
  } else {
    console.log(`  (install qrencode for a scannable code: brew install qrencode)`);
    console.log(`  ${text}`);
  }
}

function getConfiguredWorkspaces() {
  const configured = (process.env.LOUPE_WORKSPACES || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  const saved = readSavedWorkspacePaths();
  const candidates = configured.length ? configured : [ROOT, ...saved];
  const unique = [...new Set(candidates.map((item) => path.resolve(item)))];

  return unique.map((workspacePath, index) => workspaceFromPath(workspacePath, index));
}

function readSavedWorkspacePaths() {
  try {
    const parsed = JSON.parse(fs.readFileSync(WORKSPACE_STORE, "utf8"));
    return Array.isArray(parsed.workspaces) ? parsed.workspaces : [];
  } catch {
    return [];
  }
}

function saveWorkspaces() {
  fs.writeFileSync(
    WORKSPACE_STORE,
    JSON.stringify({ workspaces: workspaces.map((workspace) => workspace.path) }, null, 2)
  );
}

function workspaceFromPath(workspacePath, index) {
  const resolved = path.resolve(workspacePath);
  return {
    id: `workspace-${index}`,
    name: path.basename(resolved) || resolved,
    path: resolved
  };
}

function addWorkspace(workspacePath) {
  const resolved = path.resolve(workspacePath);
  const existing = workspaces.find((workspace) => workspace.path === resolved);
  if (existing) return existing;

  const workspace = workspaceFromPath(resolved, workspaces.length);
  workspaces.push(workspace);
  saveWorkspaces();
  return workspace;
}

function resolveWorkspace(id) {
  return workspaces.find((workspace) => workspace.id === id) || workspaces[0];
}

function getFsRoots() {
  return [
    { name: "Home", path: os.homedir() },
    { name: "Documents", path: path.join(os.homedir(), "Documents") },
    { name: "Desktop", path: path.join(os.homedir(), "Desktop") },
    { name: "Downloads", path: path.join(os.homedir(), "Downloads") },
    { name: "Volumes", path: "/Volumes" },
    { name: "Macintosh HD", path: "/" }
  ];
}

function listJsonlFiles(dirPath, files = []) {
  let entries = [];
  try {
    entries = fs.readdirSync(dirPath, { withFileTypes: true });
  } catch {
    return files;
  }

  for (const entry of entries) {
    const entryPath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      listJsonlFiles(entryPath, files);
    } else if (entry.name.endsWith(".jsonl")) {
      files.push(entryPath);
    }
  }

  return files;
}

function readLastRateLimitSnapshot(filePath) {
  let content = "";
  let fd = null;
  try {
    const stat = fs.statSync(filePath);
    const bytesToRead = Math.min(stat.size, 1024 * 1024);
    const buffer = Buffer.alloc(bytesToRead);
    fd = fs.openSync(filePath, "r");
    fs.readSync(fd, buffer, 0, bytesToRead, stat.size - bytesToRead);
    content = buffer.toString("utf8");
  } catch {
    return null;
  } finally {
    if (fd !== null) fs.closeSync(fd);
  }

  const lines = content.trim().split(/\r?\n/);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index];
    if (!line.includes("\"rate_limits\"")) continue;

    try {
      const parsed = JSON.parse(line);
      const rateLimits = parsed.payload?.rate_limits;
      if (rateLimits) {
        return {
          capturedAt: parsed.timestamp || null,
          rateLimits
        };
      }
    } catch {
      return null;
    }
  }

  return null;
}

function getCodexUsage() {
  return getUsageSnapshot(CODEX_SESSIONS_DIR);
}

function getClaudeUsage() {
  return getUsageSnapshot(CLAUDE_PROJECTS_DIR);
}

function getUsageSnapshot(rootDir) {
  const files = listJsonlFiles(rootDir)
    .map((filePath) => {
      try {
        return { path: filePath, mtimeMs: fs.statSync(filePath).mtimeMs };
      } catch {
        return null;
      }
    })
    .filter(Boolean)
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .slice(0, 40);

  for (const file of files) {
    const snapshot = readLastRateLimitSnapshot(file.path);
    if (snapshot) return snapshot;
  }

  return null;
}

function cleanFolderName(name) {
  const cleaned = String(name || "").trim();
  if (!cleaned || cleaned === "." || cleaned === ".." || cleaned.includes("/") || cleaned.includes("\0")) {
    throw new Error("Use a simple folder name without slashes.");
  }
  return cleaned;
}

function listFolders(dirPath) {
  const resolved = path.resolve(String(dirPath || os.homedir()));
  const entries = fs.readdirSync(resolved, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
    .map((entry) => ({
      name: entry.name,
      path: path.join(resolved, entry.name)
    }))
    .sort((a, b) => a.name.localeCompare(b.name));

  return {
    path: resolved,
    parent: path.dirname(resolved) === resolved ? null : path.dirname(resolved),
    roots: getFsRoots(),
    entries
  };
}

function sendJson(res, status, payload) {
  if (res.writableEnded) return;
  let body;
  try {
    body = JSON.stringify(payload);
  } catch (error) {
    status = 500;
    body = JSON.stringify({ ok: false, error: `Response could not be serialized: ${error.message}` });
  }
  if (res.headersSent) {
    res.end(body);
    return;
  }
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "access-control-allow-origin": "*"
  });
  res.end(body);
}

function isPublicApi(pathname) {
  return pathname === "/api/pairing/status";
}

function requestAuthToken(req, url) {
  const headerToken = req.headers["x-loupe-token"];
  if (typeof headerToken === "string" && headerToken.trim()) return headerToken.trim();

  const auth = req.headers.authorization;
  if (typeof auth === "string" && auth.toLowerCase().startsWith("bearer ")) {
    return auth.slice(7).trim();
  }

  // EventSource cannot set custom headers in browsers, so the SSE endpoint
  // accepts the same token as a query param.
  const queryToken = url.searchParams.get("token");
  return queryToken ? queryToken.trim() : "";
}

function isAuthorized(req, url) {
  const token = requestAuthToken(req, url);
  if (!token) return false;
  if (config.apiToken && token === config.apiToken) return true;
  const tokenHash = hashToken(token);
  const device = (config.devices || []).find((item) => item.tokenHash === tokenHash && !item.revokedAt);
  if (!device) return false;
  device.lastSeenAt = new Date().toISOString();
  device.lastIp = getClientIp(req).replace(/^::ffff:/, "");
  saveConfig();
  return true;
}

function getClientIp(req) {
  const forwarded = req.headers["x-forwarded-for"];
  if (forwarded) return forwarded.split(",")[0].trim();
  return req.socket.remoteAddress || "unknown";
}

function recordRequest(req) {
  const event = {
    at: new Date().toISOString(),
    ip: getClientIp(req).replace(/^::ffff:/, ""),
    method: req.method,
    path: new URL(req.url, `http://${req.headers.host}`).pathname,
    userAgent: req.headers["user-agent"] || "unknown"
  };
  recentRequests.unshift(event);
  recentRequests.splice(12);
  console.log(`${event.at} ${event.ip} ${event.method} ${event.path}`);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > 64_000) {
        reject(new Error("Request body too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function addEvent(session, event) {
  const enriched = { id: session.nextEventId++, at: new Date().toISOString(), ...event };
  session.events.push(enriched);
  persistState();
  for (const res of session.clients) {
    res.write(`data: ${JSON.stringify(enriched)}\n\n`);
  }
}

function spawnSessionTurn(session, message, { resume = false } = {}) {
  const harness = getHarness(session.harnessId);
  session.message = message;
  session.status = "running";

  addEvent(session, {
    type: "status",
    status: resume ? "resuming" : "starting",
    harness: session.harnessId,
    text: `${resume ? "Resuming" : "Starting"} ${harness.label} on this Mac...`
  });

  const spawner = session.harnessId === "claude-code" ? spawnClaudeCode : spawnCodex;
  const child = spawner(session, message, { resume });
  session.child = child;

  child.on("error", (error) => {
    session.status = "failed";
    addEvent(session, { type: "error", text: error.message });
  });

  child.on("close", (code) => {
    if (session._flushStdout) session._flushStdout();
    session.exitCode = code;
    session.status = code === 0 ? "completed" : "failed";
    session.child = null;
    addEvent(session, {
      type: "done",
      status: session.status,
      exitCode: code,
      text: code === 0 ? `${harness.label} session completed.` : `${harness.label} exited with code ${code}.`
    });
    // After the agent stops, push the branch (if any) and surface the PR URL.
    if (session.branch && code === 0) {
      finalizeBranch(session).catch((error) => {
        addEvent(session, { type: "branch", kind: "error", text: `Could not finalize PR: ${error.message}` });
      });
    }
  });

  return child;
}

function createSession(message, workspaceId, requestedHarness, dispatch) {
  const workspace = resolveWorkspace(workspaceId);
  const harnessId = (requestedHarness && getHarness(requestedHarness)?.available)
    ? requestedHarness
    : defaultHarnessId();
  const harness = getHarness(harnessId);
  if (!harness?.available) {
    throw new Error(`Harness "${harnessId}" is not available on this Mac. Install Codex or Claude Code.`);
  }
  if (dispatch?.mode === "branch") {
    const readiness = workspaceReadiness(workspace);
    if (!readiness.canDispatch) {
      const error = new Error(`Workspace is not ready for ticket dispatch: ${readiness.blockers.join(" ")}`);
      error.statusCode = 409;
      throw error;
    }
  }

  const id = `${harnessId}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const session = {
    id,
    harnessId,
    message,
    workspace,
    dispatch: dispatch || null, // { ticket: {repo, number, title, url, kind}, mode: "branch"|"plain" } | null
    status: "running",
    events: [],
    clients: new Set(),
    nextEventId: 0,
    startedAt: new Date().toISOString(),
    exitCode: null,
    codexThreadId: null,
    claudeSessionId: null,
    branch: null, // populated by setupBranchIfApplicable when branch mode triggers
    agentMessages: [],
    handoff: null,
    deviation: null
  };
  sessions.set(id, session);
  addEvent(session, { type: "user_message", text: message });

  // Auto-engage branch mode when the workspace is bound to a GitHub repo,
  // unless the caller explicitly opted out with dispatch.mode = "plain".
  const wantsBranch = (!session.dispatch || session.dispatch.mode !== "plain");
  if (wantsBranch) {
    setupBranchIfApplicable(session);
  }

  spawnSessionTurn(session, message);

  return session;
}

function continueSession(id, message) {
  const session = sessions.get(id);
  if (!session) {
    const error = new Error("Unknown session.");
    error.statusCode = 404;
    throw error;
  }
  if (session.status === "running" || session.child) {
    const error = new Error("Session is already running.");
    error.statusCode = 409;
    throw error;
  }
  if (session.harnessId === "codex" && !session.codexThreadId) {
    throw new Error("Codex has not reported a resumable thread ID yet.");
  }
  if (session.harnessId === "claude-code" && !session.claudeSessionId) {
    throw new Error("Claude Code has not reported a resumable session ID yet.");
  }

  addEvent(session, { type: "user_message", text: message });
  spawnSessionTurn(session, message, { resume: true });
  return session;
}

function toStringList(value, limit = 12) {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => {
      if (typeof item === "string") return item.trim();
      if (item && typeof item === "object") {
        return [item.file, item.path, item.change, item.summary, item.command, item.concern, item.risk, item.assumption]
          .filter(Boolean)
          .join(" — ")
          .trim();
      }
      return String(item || "").trim();
    })
    .filter(Boolean)
    .slice(0, limit);
}

function normalizeHandoff(raw, { session, changedFiles = [] } = {}) {
  const source = raw && typeof raw === "object" ? raw : {};
  const plan = session?.dispatch?.plan || {};
  const confidence = Math.max(0, Math.min(1, Number(source.confidence?.overall ?? source.confidence ?? 0.5) || 0.5));
  return {
    tldr: String(source.tldr || source.summary || source.tl_dr || "Agent completed the requested change.").trim(),
    what_changed: toStringList(source.what_changed || source.whatChanged || source.what_i_did || source.changes, 16),
    files_changed: toStringList(source.files_changed || source.filesChanged || source.files || changedFiles, 40),
    tests_run: toStringList(source.tests_run || source.testsRun || source.test_plan?.ran || source.tests, 16),
    tests_not_run: toStringList(source.tests_not_run || source.testsNotRun || source.test_plan?.did_not_run, 16),
    assumptions: toStringList(source.assumptions || source.verify_these || source.verifyThese || plan.openQuestions, 16),
    risks: toStringList(source.risks || source.low_confidence_areas || source.confidence?.low_confidence_areas || plan.risks, 16),
    confidence
  };
}

function tryExtractHandoff(text, session) {
  if (!text || !/handoff|tldr|what_changed|files_changed|tests_run/i.test(text)) return null;
  try {
    return normalizeHandoff(extractJsonObject(text), { session });
  } catch {
    return null;
  }
}

function noteAgentMessage(session, text) {
  const trimmed = String(text || "").trim();
  if (!trimmed) return;
  if (session.agentMessages.at(-1) === trimmed) return;
  session.agentMessages.push(trimmed);
  const handoff = tryExtractHandoff(trimmed, session);
  if (handoff) {
    session.handoff = handoff;
    addEvent(session, { type: "handoff", kind: "captured", handoff });
  }
}

function changedFilesFromCachedDiff(cwd) {
  const result = gitRun(cwd, ["diff", "--cached", "--name-status"]);
  if (result.status !== 0) return [];
  return result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim().split(/\s+/).slice(-1)[0])
    .filter(Boolean);
}

function buildSessionHandoff(session, changedFiles) {
  const fallback = normalizeHandoff({
    tldr: session.handoff?.tldr || session.dispatch?.plan?.summary || session.agentMessages.at(-1) || "Agent completed the requested change.",
    what_changed: session.handoff?.what_changed?.length ? session.handoff.what_changed : [session.agentMessages.at(-1)].filter(Boolean),
    files_changed: changedFiles,
    tests_run: session.handoff?.tests_run || [],
    tests_not_run: session.handoff?.tests_not_run || ["Not reported by agent."],
    assumptions: session.handoff?.assumptions || session.dispatch?.plan?.openQuestions || [],
    risks: session.handoff?.risks || session.dispatch?.plan?.risks || [],
    confidence: session.handoff?.confidence ?? 0.5
  }, { session, changedFiles });
  session.handoff = fallback;
  return fallback;
}

function compareBlueprintHandoff(plan, changedFiles, handoff) {
  const predicted = new Set((plan?.files || []).map((file) => file.path).filter(Boolean));
  for (const file of plan?.likelyFiles || []) predicted.add(file);
  const actual = new Set((changedFiles || handoff?.files_changed || []).filter(Boolean));
  return {
    filesTouchedNotPredicted: [...actual].filter((file) => !predicted.has(file)),
    filesPredictedNotTouched: [...predicted].filter((file) => !actual.has(file)),
    migrationsPredicted: (plan?.migrations || []).length,
    migrationsTouched: [...actual].filter((file) => /(^|\/)(migrations|db\/migrate|alembic)(\/|$)/i.test(file)).length,
    confidenceDelta: typeof handoff?.confidence === "number" && typeof (plan?.blueprintConfidence ?? plan?.confidence) === "number"
      ? handoff.confidence - (plan.blueprintConfidence ?? plan.confidence)
      : null
  };
}

function markdownList(items, empty = "_None reported._") {
  return items?.length ? items.map((item) => `- ${item}`).join("\n") : empty;
}

function formatPrBody(session, handoff, { branch, base, commitSha }) {
  const ticket = session.dispatch?.ticket;
  const plan = session.dispatch?.plan;
  const deviation = session.deviation || null;
  return `## What I did
${handoff.tldr}

## Why
${ticket?.url ? `Refs ${ticket.url}` : "Requested from Loupe."}

## Approach
${plan?.summary || "No approved plan summary was recorded."}

## Files changed (${handoff.files_changed.length})
${markdownList(handoff.files_changed)}

## Blueprint check
${deviation ? markdownList([
  deviation.filesTouchedNotPredicted.length ? `Touched but not predicted: ${deviation.filesTouchedNotPredicted.join(", ")}` : "No unpredicted files touched.",
  deviation.filesPredictedNotTouched.length ? `Predicted but not touched: ${deviation.filesPredictedNotTouched.join(", ")}` : "All predicted files were either touched or intentionally avoided.",
  `Migrations predicted/touched: ${deviation.migrationsPredicted}/${deviation.migrationsTouched}`
]) : "_No Blueprint deviation computed._"}

## I want you to double-check
${markdownList([...handoff.assumptions, ...handoff.risks])}

## Verified
${markdownList(handoff.tests_run)}

## Not verified
${markdownList(handoff.tests_not_run)}

## Confidence
${Math.round(handoff.confidence * 100)}%

---
Generated by Loupe via ${session.harnessId}.

- Branch: \`${branch}\`
- Base: \`${base}\`
- Commit: \`${commitSha}\`
- Session: \`${session.id}\`
`;
}

function buildPlanPrompt(ticket, workspace) {
  const labels = Array.isArray(ticket.labels) && ticket.labels.length ? ticket.labels.join(", ") : "none";
  return `
You are planning a coding-agent task for Loupe. Do not edit files. Inspect the repository only enough to produce a concise implementation plan.

Return ONLY valid JSON with this exact shape:
{
  "summary": "one sentence",
  "likelyFiles": ["path/or/glob"],
  "risks": ["risk or assumption"],
  "tests": ["test command or test file"],
  "openQuestions": ["question"],
  "confidence": 0.0
}

Ticket:
- Repo: ${ticket.repo || "unknown"}
- Number: ${ticket.number || "unknown"}
- Title: ${ticket.title || "Untitled"}
- URL: ${ticket.url || "unknown"}
- Labels: ${labels}

Body:
${ticket.body || "(no body provided)"}

Workspace: ${workspace.path}
`.trim();
}

function normalizePlan(raw, ticket, workspace, harnessId) {
  const source = raw && typeof raw === "object" ? raw : {};
  const list = (value) => Array.isArray(value)
    ? value.map((item) => String(item || "").trim()).filter(Boolean).slice(0, 12)
    : [];
  const confidence = Math.max(0, Math.min(1, Number(source.confidence) || 0.5));
  return {
    id: `plan-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
    createdAt: new Date().toISOString(),
    harness: harnessId,
    workspace,
    ticket,
    summary: String(source.summary || `Plan for ${ticket.repo || "repo"}#${ticket.number || "ticket"}`).trim(),
    likelyFiles: list(source.likelyFiles || source.likely_files || source.files),
    risks: list(source.risks),
    tests: list(source.tests || source.testPlan || source.test_plan),
    openQuestions: list(source.openQuestions || source.open_questions || source.questions),
    confidence
  };
}

function extractJsonObject(text) {
  if (text && typeof text === "object") return text;
  const trimmed = String(text || "").trim();
  if (!trimmed) throw new Error("Plan runner returned no output.");
  try {
    return JSON.parse(trimmed);
  } catch {}

  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced) {
    try { return JSON.parse(fenced[1].trim()); } catch {}
  }

  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start >= 0 && end > start) {
    return JSON.parse(trimmed.slice(start, end + 1));
  }
  throw new Error("Plan runner did not return parseable JSON.");
}

function firstParseableJsonObject(candidates) {
  let lastError = null;
  for (const candidate of candidates) {
    if (candidate === undefined || candidate === null || candidate === "") continue;
    try {
      return extractJsonObject(candidate);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError || new Error("Plan runner did not return parseable JSON.");
}

function runCapture(command, args, cwd, { timeout = 180_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...process.env, NO_COLOR: "1", FORCE_COLOR: "0" },
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("Plan generation timed out."));
    }, timeout);
    child.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
    child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) {
        resolve({ stdout, stderr });
      } else {
        reject(new Error((stderr || stdout || `${command} exited with code ${code}`).trim().slice(0, 1200)));
      }
    });
  });
}

function stableHash(value) {
  return crypto
    .createHash("sha256")
    .update(typeof value === "string" ? value : JSON.stringify(value))
    .digest("hex")
    .slice(0, 24);
}

function ticketHash(ticket) {
  return stableHash({
    repo: ticket.repo || "",
    number: ticket.number || "",
    title: ticket.title || "",
    body: ticket.body || "",
    labels: ticket.labels || [],
    updatedAt: ticket.updatedAt || ticket.updated_at || ""
  });
}

function safeCacheName(value) {
  return String(value || "unknown").replace(/[^a-z0-9._-]+/gi, "-").replace(/^-+|-+$/g, "").slice(0, 80) || "unknown";
}

function loadBlueprintArtifacts() {
  const prompt = fs.readFileSync(BLUEPRINT_PROMPT_FILE, "utf8");
  const schema = JSON.parse(fs.readFileSync(BLUEPRINT_SCHEMA_FILE, "utf8"));
  return { prompt, schema };
}

function blueprintCachePath(ticket, workspace) {
  const binding = workspaceRepoBinding(workspace);
  const repoName = safeCacheName(ticket.repo || (binding ? `${binding.owner}-${binding.repo}` : workspace.name));
  // Key by (repo, ticket) only — NOT repo HEAD — so a Blueprint persists across
  // commits. Staleness vs the current HEAD is computed separately, at file level.
  return path.join(BLUEPRINT_CACHE_DIR, `${repoName}.${ticketHash(ticket)}.json`);
}

function blueprintCachePrefix(ticket, workspace) {
  const binding = workspaceRepoBinding(workspace);
  const repoName = safeCacheName(ticket.repo || (binding ? `${binding.owner}-${binding.repo}` : workspace.name));
  return `${repoName}.${ticketHash(ticket)}.`;
}

function readBlueprintCacheFile(filePath, ticket, workspace, { stale = false } = {}) {
  const cached = JSON.parse(fs.readFileSync(filePath, "utf8"));
  const blueprint = normalizeBlueprint(cached, ticket, workspace, cached.provider || cached._provider || "cache", {
    cached: true,
    cachePath: filePath,
    repoSha: cached.repoSha || cached._repo_sha,
    ticketHash: cached.ticketHash || cached._ticket_hash,
    costUsd: cached.costUsd ?? cached._cost_usd,
    durationMs: cached.durationMs ?? cached._duration_ms,
    model: cached.model || cached._model
  });
  if (cached.degraded) {
    blueprint.degraded = true;
    blueprint.degradedReason = cached.degradedReason || "This is a rough estimate; tap refresh to retry full analysis.";
  }
  if (stale) {
    blueprint.stale = true;
    blueprint.staleReason = "Repo HEAD changed since this Blueprint was generated.";
  }
  return blueprint;
}

function publicBlueprint(blueprint) {
  if (!blueprint) return null;
  return {
    id: blueprint.id,
    createdAt: blueprint.createdAt,
    outcome: blueprint.outcome,
    missingInfo: blueprint.missingInfo || [],
    summary: blueprint.summary,
    size: blueprint.size,
    files: blueprint.files || [],
    deps: blueprint.deps || [],
    migrations: blueprint.migrations || [],
    riskAreas: blueprint.riskAreas || [],
    outOfScope: blueprint.outOfScope || [],
    openQuestions: blueprint.openQuestions || [],
    defaultAgent: blueprint.defaultAgent || null,
    blueprintConfidence: blueprint.blueprintConfidence ?? blueprint.confidence ?? null,
    provider: blueprint.provider,
    cached: !!blueprint.cached,
    stale: !!blueprint.stale,
    staleReason: blueprint.staleReason || null,
    repoSha: blueprint.repoSha || null,
    ticketHash: blueprint.ticketHash || null,
    likelyFiles: blueprint.likelyFiles || (blueprint.files || []).map((file) => file.path).filter(Boolean),
    risks: blueprint.risks || [],
    tests: blueprint.tests || [],
    confidence: blueprint.confidence ?? blueprint.blueprintConfidence ?? null
  };
}

function readCachedBlueprintForTicket(ticket, workspace) {
  const exactPath = blueprintCachePath(ticket, workspace);
  try {
    return publicBlueprint(readBlueprintCacheFile(exactPath, ticket, workspace));
  } catch {
    try {
      const prefix = blueprintCachePrefix(ticket, workspace);
      const candidates = fs.readdirSync(BLUEPRINT_CACHE_DIR)
        .filter((name) => name.startsWith(prefix) && name.endsWith(".json"))
        .map((name) => {
          const filePath = path.join(BLUEPRINT_CACHE_DIR, name);
          return { filePath, mtimeMs: fs.statSync(filePath).mtimeMs };
        })
        .sort((a, b) => b.mtimeMs - a.mtimeMs);
      if (candidates.length) {
        return publicBlueprint(readBlueprintCacheFile(candidates[0].filePath, ticket, workspace, { stale: true }));
      }
    } catch {}
    return null;
  }
}

function blueprintJobKey(ticket, workspace) {
  return blueprintCachePath(ticket, workspace);
}

function publicBlueprintJob(job) {
  const status = job?.status || "queued";
  const message = status === "failed"
    ? (job.error || "Blueprint generation failed.")
    : status === "running"
      ? "Analyzing ticket..."
      : "Queued for analysis...";
  return {
    status,
    outcome: "needs_info",
    summary: message,
    size: null,
    files: [],
    deps: [],
    migrations: [],
    riskAreas: [],
    risk_areas: [],
    outOfScope: [],
    out_of_scope: [],
    openQuestions: [],
    open_questions: [],
    missingInfo: status === "failed" ? [message] : [],
    missing_info: status === "failed" ? [message] : [],
    defaultAgent: null,
    default_agent: null,
    blueprintConfidence: null,
    blueprint_confidence: null,
    confidence: null,
    costEstimate: null,
    cost_estimate: null,
    provider: null,
    cached: false,
    stale: false,
    staleReason: null,
    stale_reason: null,
    repoSha: job?.repoSha || repoHeadSha(job.workspace),
    repo_sha: job?.repoSha || repoHeadSha(job.workspace),
    ticketHash: job?.ticketHash || ticketHash(job.ticket),
    ticket_hash: job?.ticketHash || ticketHash(job.ticket)
  };
}

function enqueueBlueprintForTicket(ticket, workspace) {
  fs.mkdirSync(BLUEPRINT_CACHE_DIR, { recursive: true });
  const key = blueprintJobKey(ticket, workspace);
  const existing = blueprintJobs.get(key);
  if (existing && ["queued", "running"].includes(existing.status)) {
    return publicBlueprintJob(existing);
  }
  if (existing?.status === "done" && existing.blueprint) {
    return existing.blueprint;
  }
  if (existing?.status === "failed" && Date.now() - Date.parse(existing.updatedAt || 0) < 5 * 60_000) {
    return publicBlueprintJob(existing);
  }
  const job = {
    key,
    status: "queued",
    ticket: { ...ticket, binding: undefined, blueprint: undefined },
    workspace,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    repoSha: repoHeadSha(workspace),
    ticketHash: ticketHash(ticket),
    error: null
  };
  blueprintJobs.set(key, job);
  blueprintQueue.push(job);
  pumpBlueprintQueue();
  return publicBlueprintJob(job);
}

function pumpBlueprintQueue() {
  while (activeBlueprintJobs < MAX_BACKGROUND_BLUEPRINT_JOBS && blueprintQueue.length) {
    const job = blueprintQueue.shift();
    if (!job || job.status !== "queued") continue;
    activeBlueprintJobs += 1;
    job.status = "running";
    job.updatedAt = new Date().toISOString();
    createBlueprint(job.ticket, job.workspace.id, "claude-code")
      .then((blueprint) => {
        job.status = "done";
        job.blueprint = publicBlueprint(blueprint);
        job.updatedAt = new Date().toISOString();
        inboxCache.fetchedAt = 0;
      })
      .catch((error) => {
        job.status = "failed";
        job.error = error?.message || String(error);
        job.updatedAt = new Date().toISOString();
        inboxCache.fetchedAt = 0;
        console.warn(`Background Blueprint failed for ${job.ticket?.repo || "repo"}#${job.ticket?.number || "ticket"}: ${job.error}`);
      })
      .finally(() => {
        activeBlueprintJobs -= 1;
        pumpBlueprintQueue();
      });
  }
}

// File-level staleness: a Blueprint is "stale" only if a file it actually
// references changed between its generation HEAD and the current HEAD. Unrelated
// commits do NOT invalidate it. This sets a badge; it never regenerates.
function annotateStaleness(blueprint, workspace) {
  blueprint.stale = false;
  blueprint.staleFiles = [];
  const genSha = blueprint.repoSha;
  if (!genSha) return;
  let currentSha;
  try { currentSha = repoHeadSha(workspace); } catch { return; }
  if (!currentSha || genSha === currentSha) return;
  const files = (blueprint.files || []).map((f) => f.path).filter(Boolean);
  if (!files.length) return;
  try {
    const out = spawnSync("git", ["-C", workspace.path, "diff", "--name-only", genSha, currentSha],
      { timeout: 3000, encoding: "utf8" });
    if (out.status !== 0) return;
    const changed = new Set(out.stdout.split(/\r?\n/).map((s) => s.trim()).filter(Boolean));
    const hit = files.filter((f) => changed.has(f));
    if (hit.length) {
      blueprint.stale = true;
      blueprint.staleFiles = hit;
      blueprint.staleReason = `${hit.length} tracked file${hit.length > 1 ? "s" : ""} changed since this Blueprint was generated.`;
    }
  } catch {}
}

function renderBlueprintPrompt(ticket, workspace) {
  const { prompt, schema } = loadBlueprintArtifacts();
  const systemPrompt = prompt
    .replaceAll("{repo}", ticket.repo || "unknown")
    .replaceAll("{workspace_path}", workspace.path)
    .replaceAll("{repo_sha}", repoHeadSha(workspace));
  const labels = Array.isArray(ticket.labels) && ticket.labels.length ? ticket.labels.join(", ") : "none";
  const userPrompt = `# Ticket: ${ticket.repo || "unknown"}#${ticket.number || "unknown"}

## Title
${ticket.title || "Untitled"}

## URL
${ticket.url || "unknown"}

## Labels
${labels}

## Body
${ticket.body || "(empty)"}`;
  return { systemPrompt, schema, userPrompt };
}

function asList(value, limit = 12) {
  return Array.isArray(value)
    ? value.map((item) => String(item || "").trim()).filter(Boolean).slice(0, limit)
    : [];
}

function normalizeBlueprint(raw, ticket, workspace, providerId, meta = {}) {
  const source = raw && typeof raw === "object" ? raw : {};
  const outcome = source.outcome === "needs_info" ? "needs_info" : "ready";
  const fileItems = Array.isArray(source.files) ? source.files : [];
  const files = outcome === "needs_info" ? [] : fileItems
    .map((file) => {
      if (typeof file === "string") {
        return { path: file, is_new: false, confidence: 0.7, why: "Predicted by planner." };
      }
      return {
        path: String(file?.path || "").trim(),
        is_new: !!file?.is_new,
        confidence: Math.max(0, Math.min(1, Number(file?.confidence) || 0.5)),
        why: String(file?.why || "Predicted by planner.").trim().slice(0, 200)
      };
    })
    .filter((file) => file.path)
    .slice(0, 6);
  const deps = Array.isArray(source.deps) ? source.deps.map((dep) => ({
    name: String(dep?.name || "").trim(),
    ecosystem: String(dep?.ecosystem || "other").trim() || "other",
    reason: String(dep?.reason || "").trim().slice(0, 200)
  })).filter((dep) => dep.name).slice(0, 8) : [];
  const migrations = Array.isArray(source.migrations) ? source.migrations.map((migration) => ({
    purpose: String(migration?.purpose || "").trim().slice(0, 200),
    risk: ["low", "medium", "high"].includes(migration?.risk) ? migration.risk : "medium",
    kind: ["schema", "data", "index"].includes(migration?.kind) ? migration.kind : "schema"
  })).filter((migration) => migration.purpose).slice(0, 8) : [];
  const riskVocabulary = new Set(["payments", "auth", "security", "migration", "ml-quality", "concurrency", "data-loss", "performance", "infra", "observability"]);
  const riskAreas = asList(source.risk_areas || source.riskAreas, 8).filter((risk) => riskVocabulary.has(risk));
  const outOfScope = Array.isArray(source.out_of_scope) ? source.out_of_scope.map((item) => ({
    path: String(item?.path || "").trim(),
    reason: String(item?.reason || "").trim().slice(0, 200)
  })).filter((item) => item.path).slice(0, 8) : [];
  const confidence = Math.max(0, Math.min(1, Number(source.blueprint_confidence ?? source.confidence) || 0.5));
  const summary = String(source.summary || (outcome === "needs_info" ? "Ticket needs more information before dispatch." : `Blueprint for ${ticket.repo || "repo"}#${ticket.number || "ticket"}`)).trim();

  return {
    id: source.id || `blueprint-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
    createdAt: source.createdAt || new Date().toISOString(),
    outcome,
    missingInfo: asList(source.missing_info || source.missingInfo, 8),
    summary,
    size: ["S", "M", "L", "XL"].includes(source.size) ? source.size : "M",
    files,
    deps,
    migrations,
    riskAreas,
    outOfScope,
    defaultAgent: ["claude", "codex"].includes(source.default_agent || source.defaultAgent) ? (source.default_agent || source.defaultAgent) : null,
    blueprintConfidence: confidence,
    provider: providerId,
    harness: providerId,
    workspace,
    ticket,
    cached: !!meta.cached,
    cachePath: meta.cachePath || null,
    repoSha: meta.repoSha || repoHeadSha(workspace),
    ticketHash: meta.ticketHash || ticketHash(ticket),
    costUsd: meta.costUsd ?? null,
    durationMs: meta.durationMs ?? null,
    model: meta.model || null,
    usage: meta.usage || null,
    // Backward-compatible fields for the existing plan UI and dispatch context.
    likelyFiles: files.map((file) => file.path),
    risks: [...riskAreas, ...migrations.map((migration) => `${migration.kind} migration: ${migration.purpose}`)],
    tests: asList(source.tests || source.test_plan || source.testPlan, 8),
    openQuestions: asList(source.open_questions || source.openQuestions || source.questions, 3),
    confidence
  };
}

function roundUsd(value) {
  return Math.round(Number(value || 0) * 10000) / 10000;
}

// ---------- Cost model + model routing ----------
// Per-million-token USD pricing (May 2026). Single source of truth for both
// measured (blueprint) and estimated (execution) cost. Update as prices move.
const MODEL_PRICING = {
  opus:   { in: 5.0,  out: 25.0, cachedIn: 0.5 },   // Claude Opus 4.7
  sonnet: { in: 3.0,  out: 15.0, cachedIn: 0.3 },   // Claude Sonnet 4.6
  haiku:  { in: 1.0,  out: 5.0,  cachedIn: 0.1 },   // Claude Haiku 4.5
  codex:  { in: 1.25, out: 10.0, cachedIn: 0.125 }  // OpenAI codex-tier (approx)
};
function pricingFor(model) {
  const m = String(model || "").toLowerCase();
  if (m.includes("opus")) return { tier: "opus", ...MODEL_PRICING.opus };
  if (m.includes("sonnet")) return { tier: "sonnet", ...MODEL_PRICING.sonnet };
  if (m.includes("haiku")) return { tier: "haiku", ...MODEL_PRICING.haiku };
  if (m.includes("codex") || m.includes("gpt")) return { tier: "codex", ...MODEL_PRICING.codex };
  return null;
}
// Plan-and-execute routing: strong reasoning model plans, efficient coder executes.
// Overridable via env or config.models.{blueprint,execution}.
function blueprintModelAlias() {
  return process.env.LOUPE_BLUEPRINT_MODEL || config.models?.blueprint || "opus";
}
function executionModelAlias() {
  return process.env.LOUPE_EXECUTION_MODEL || config.models?.execution || "sonnet";
}
// Hybrid blueprint routing: Sonnet for routine tickets (cheap), Opus only when
// the ticket touches a risk area where a wrong plan is costly. Override via
// LOUPE_BLUEPRINT_MODEL or config.models.blueprint.
function blueprintModelForTicket(ticket) {
  const override = process.env.LOUPE_BLUEPRINT_MODEL || config.models?.blueprint;
  if (override) return override;
  const hay = `${(ticket?.labels || []).join(" ")} ${ticket?.title || ""} ${ticket?.body || ""}`.toLowerCase();
  const risky = ["auth", "login", "password", "token", "oauth", "payment", "billing",
    "stripe", "charge", "refund", "security", "vulnerab", "migration", "schema",
    "encrypt", "crypto", "permission", "privacy", "pii"].some((k) => hay.includes(k));
  return risky ? "opus" : "sonnet";
}
// Exact cost from token usage (used for the MEASURED blueprint cost).
function usdFromUsage(model, usage) {
  const p = pricingFor(model);
  if (!p || !usage) return null;
  const cacheRead = usage.cache_read_input_tokens ?? usage.cacheReadInputTokens ?? 0;
  const cacheWrite = usage.cache_creation_input_tokens ?? usage.cacheCreationInputTokens ?? 0;
  const input = usage.input_tokens ?? usage.inputTokens ?? 0;   // fresh, uncached
  const output = usage.output_tokens ?? usage.outputTokens ?? 0;
  // Cache writes bill at ~1.25× base input (5-min TTL); reads at the cached rate.
  return roundUsd((input * p.in + cacheWrite * p.in * 1.25 + cacheRead * p.cachedIn + output * p.out) / 1e6);
}
// Execution token estimate per size bucket (input context, output diff).
// Heuristic seed — replaced by calibrated values once real runs accumulate.
const EXEC_TOKENS = {
  S:  { inLow: 25_000,  inHigh: 60_000,  out: 4_000 },
  M:  { inLow: 60_000,  inHigh: 150_000, out: 10_000 },
  L:  { inLow: 150_000, inHigh: 350_000, out: 25_000 },
  XL: { inLow: 350_000, inHigh: 800_000, out: 60_000 }
};

function estimateExecutionCost(blueprint) {
  if (!blueprint || blueprint.outcome !== "ready") return null;
  const size = ["S", "M", "L", "XL"].includes(blueprint.size) ? blueprint.size : "M";
  const bucket = EXEC_TOKENS[size];
  const fileCount = Array.isArray(blueprint.files) ? blueprint.files.length : 0;
  const riskCount = Array.isArray(blueprint.riskAreas) ? blueprint.riskAreas.length : 0;
  const factor = 1 + Math.max(0, fileCount - 3) * 0.08 + riskCount * 0.12;
  const model = executionModelAlias();
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
  // Prefer cost computed from real token usage × our pricing table; fall back to
  // the provider-reported cost (e.g. Claude CLI total_cost_usd).
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

function inferBlueprintFromTicket(ticket) {
  const text = `${ticket.title || ""}\n${ticket.body || ""}`;
  const fileCandidates = new Set();
  function addFileCandidate(value) {
    const candidate = String(value || "")
      .replace(/\([^)]*\)/g, "")
      .replace(/^new\s+/i, "")
      .replace(/[.,;:]+$/g, "")
      .trim();
    if (candidate.includes("/") && !/\s/.test(candidate)) fileCandidates.add(candidate);
  }
  for (const match of text.matchAll(/`([^`]+\.[A-Za-z0-9]+)`/g)) {
    addFileCandidate(match[1]);
  }
  for (const match of text.matchAll(/(?:Files?|Suggested files?)\s*:\s*([^\n]+)/gi)) {
    for (const part of String(match[1] || "").split(/[,;]/)) {
      addFileCandidate(part.replace(/[`*]/g, ""));
    }
  }
  const lower = text.toLowerCase();
  const risks = [];
  for (const risk of ["payments", "auth", "security", "migration", "concurrency", "data-loss", "performance", "infra", "observability"]) {
    if (lower.includes(risk) || (risk === "concurrency" && /race|concurrent|parallel/.test(lower))) risks.push(risk);
  }
  const files = [...fileCandidates].slice(0, 6);
  const size = text.length > 3500 || files.length > 4 ? "L" : text.length > 1200 || files.length > 2 ? "M" : "S";
  return {
    outcome: "ready",
    summary: String(ticket.body || ticket.title || "Ticket is ready for dispatch.")
      .replace(/\s+/g, " ")
      .slice(0, 220),
    size,
    files: files.map((file) => ({
      path: file,
      is_new: /new|add|create/i.test(text),
      confidence: 0.74,
      why: "Mentioned directly in the ticket."
    })),
    deps: [],
    migrations: [],
    risk_areas: risks.slice(0, 8),
    out_of_scope: [],
    open_questions: [],
    missing_info: [],
    default_agent: risks.some((risk) => ["auth", "security", "payments", "migration"].includes(risk)) ? "claude" : "codex",
    blueprint_confidence: files.length ? 0.72 : 0.58,
    tests: ["Run the app/build checks touched by the changed files."]
  };
}

function publicBlueprint(blueprint) {
  if (!blueprint || blueprint.status === "not_started") return blueprint;
  const { workspace, ticket, ...rest } = blueprint;
  const costEstimate = blueprintCostEstimate(blueprint);
  return {
    ...rest,
    risk_areas: blueprint.riskAreas || [],
    out_of_scope: blueprint.outOfScope || [],
    open_questions: blueprint.openQuestions || [],
    missing_info: blueprint.missingInfo || [],
    default_agent: blueprint.defaultAgent || null,
    blueprint_confidence: blueprint.blueprintConfidence ?? blueprint.confidence ?? null,
    // Degraded = real planner failed and we fell back to ticket-text heuristics.
    // The card must show this rather than presenting it as a confident $0 plan.
    degraded: blueprint.provider === "local-heuristic" || blueprint.model === "local-heuristic",
    stale_reason: blueprint.staleReason || null,
    repo_sha: blueprint.repoSha || null,
    ticket_hash: blueprint.ticketHash || null,
    cost_estimate: costEstimate,
    costEstimate,
    workspace: workspace ? { id: workspace.id, name: workspace.name, path: workspace.path } : null,
    ticket: ticket ? {
      kind: ticket.kind,
      id: ticket.id,
      number: ticket.number,
      title: ticket.title,
      url: ticket.url,
      repo: ticket.repo,
      labels: Array.isArray(ticket.labels) ? ticket.labels : [],
      updatedAt: ticket.updatedAt,
      createdAt: ticket.createdAt,
      author: ticket.author || null
    } : null
  };
}

function validateBlueprint(blueprint) {
  if (!["ready", "needs_info"].includes(blueprint.outcome)) {
    throw new Error("Blueprint outcome must be ready or needs_info.");
  }
  if (blueprint.outcome === "needs_info" && !blueprint.missingInfo.length) {
    throw new Error("needs_info Blueprint must include missing_info.");
  }
  if (blueprint.outcome === "ready" && !blueprint.summary) {
    throw new Error("ready Blueprint must include a summary.");
  }
  return blueprint;
}

class PlanningProvider {
  constructor(deps) {
    this.deps = deps;
  }
  get id() { throw new Error("Provider id is required."); }
  get label() { return this.id; }
  isAvailable() { return false; }
  async generateBlueprint() { throw new Error("Provider generateBlueprint is required."); }
}

class ClaudeCliProvider extends PlanningProvider {
  get id() { return "claude-cli"; }
  get label() { return "Claude Code (CLI)"; }
  isAvailable() {
    return !!getHarness("claude-code")?.available;
  }
  async generateBlueprint({ systemPrompt, schema, userPrompt, cwd, ticket }) {
    const schemaPath = path.join(LOUPE_HOME, "schemas", "blueprint.schema.json");
    fs.mkdirSync(path.dirname(schemaPath), { recursive: true });
    fs.writeFileSync(schemaPath, JSON.stringify(schema));
    try { fs.chmodSync(schemaPath, 0o600); } catch {}

    const model = blueprintModelForTicket(ticket);
    const args = [
      "-p", userPrompt,
      "--append-system-prompt", systemPrompt,
      "--output-format", "json",
      "--json-schema", JSON.stringify(schema),
      "--model", model,
      "--permission-mode", "dontAsk",
      "--allowedTools", "Read,Glob,Grep",
      "--add-dir", cwd,
      // Fewer turns = less context re-sent each turn = much lower cost.
      "--max-turns", "8"
    ];
    const { stdout } = await runCapture(CLAUDE_BIN, args, cwd, { timeout: 120_000 });
    const parsed = JSON.parse(stdout);
    const candidate = firstParseableJsonObject([parsed.structured_output, parsed.result, parsed.response, parsed.content, stdout]);
    const structuredOutput = candidate?.structured_output || candidate;
    if (!structuredOutput?.outcome) {
      const detail = {
        keys: Object.keys(parsed || {}),
        result: typeof parsed?.result === "string" ? parsed.result.slice(0, 300) : parsed?.result,
        permissionDenials: parsed?.permission_denials || []
      };
      throw new Error(`Claude CLI did not return Blueprint structured_output: ${JSON.stringify(detail)}`);
    }
    return {
      structured_output: structuredOutput,
      cost_usd: parsed.total_cost_usd ?? null,
      usage: parsed.usage ?? null,
      duration_ms: parsed.duration_ms ?? null,
      // CLI often omits the model in JSON output; fall back to the one we routed.
      model: parsed.model ?? model,
      provider: this.id
    };
  }
}

class CodexCliProvider extends PlanningProvider {
  get id() { return "codex-cli"; }
  get label() { return "Codex CLI"; }
  isAvailable() {
    return !!getHarness("codex")?.available;
  }
  async generateBlueprint({ systemPrompt, schema, userPrompt, cwd }) {
    const prompt = `${systemPrompt}

The required JSON Schema is:
${JSON.stringify(schema)}

Return only the JSON object. Do not wrap it in markdown.

${userPrompt}`;
    const args = [
      "exec",
      "--json",
      "--sandbox", "read-only",
      "--skip-git-repo-check",
      "-C", cwd,
      prompt
    ];
    const { stdout } = await runCapture(CODEX_BIN, args, cwd, { timeout: 120_000 });
    return {
      structured_output: parseCodexPlanOutput(stdout),
      cost_usd: null,
      duration_ms: null,
      model: null,
      provider: this.id
    };
  }
}

const PLANNING_REGISTRY = [
  new ClaudeCliProvider(),
  new CodexCliProvider()
];

const ISSUE_DRAFT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["title", "body"],
  properties: {
    title: {
      type: "string",
      minLength: 8,
      maxLength: 120,
      description: "A concise, actionable GitHub issue title."
    },
    body: {
      type: "string",
      minLength: 40,
      maxLength: 6000,
      description: "A complete GitHub issue body in Markdown."
    }
  }
};

function getActivePlanningProvider(requestedHarness) {
  return getPlanningProviderCandidates(requestedHarness)[0] || null;
}

function getPlanningProviderCandidates(requestedHarness) {
  const requestedProvider = config.blueprint?.provider;
  const available = PLANNING_REGISTRY.filter((provider) => provider.isAvailable());
  const preferred = [
    requestedProvider,
    requestedHarness === "claude-code" ? "claude-cli" : null,
    requestedHarness === "codex" ? "codex-cli" : null,
    "claude-cli",
    "codex-cli"
  ].filter(Boolean);

  const candidates = [];
  for (const id of preferred) {
    const match = available.find((provider) => provider.id === id);
    if (match && !candidates.includes(match)) candidates.push(match);
  }
  for (const provider of available) {
    if (!candidates.includes(provider)) candidates.push(provider);
  }
  return candidates;
}

function parseCodexPlanOutput(stdout) {
  let lastAgentMessage = "";
  for (const line of String(stdout || "").split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const payload = JSON.parse(line);
      const item = payload.item;
      if (item?.type === "agent_message" && item.text) lastAgentMessage = item.text;
    } catch {}
  }
  return extractJsonObject(lastAgentMessage || stdout);
}

function parseClaudePlanOutput(stdout) {
  const parsed = JSON.parse(stdout);
  return extractJsonObject(parsed.result || parsed.response || parsed.content || stdout);
}

function normalizeIssueDraft(raw, originalMessage) {
  const source = raw && typeof raw === "object" ? raw : {};
  const fallbackTitle = String(originalMessage || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find(Boolean) || "Draft GitHub issue";
  const title = String(source.title || fallbackTitle)
    .replace(/^#+\s*/, "")
    .trim()
    .slice(0, 120);
  const body = String(source.body || originalMessage || "")
    .trim()
    .slice(0, 6000);
  return {
    title: title || "Draft GitHub issue",
    body: body || String(originalMessage || "").trim()
  };
}

async function draftGithubIssue({ message, workspaceId, requestedHarness }) {
  const workspace = resolveWorkspace(workspaceId);
  const available = PLANNING_REGISTRY.filter((provider) => provider.isAvailable());
  if (!available.length) {
    const error = new Error("No local agent is available to draft the issue. Install Codex or Claude Code and refresh.");
    error.statusCode = 503;
    throw error;
  }
  const binding = workspaceRepoBinding(workspace);
  const repo = binding ? `${binding.owner}/${binding.repo}` : "unknown";
  const systemPrompt = `You draft GitHub issues for Loupe users. Convert the user's rough request into a ready-to-review GitHub issue.

Rules:
- Do not claim the issue was created.
- Do not call tools or access the network.
- Preserve the user's intent, but rewrite it as an actionable issue for a developer.
- Include useful sections when implied: Problem, Desired behavior, Acceptance criteria, Suggested files, Test plan.
- Return only JSON matching the schema.`;
  const userPrompt = `Workspace: ${workspace.name}
Path: ${workspace.path}
Repo: ${repo}

User request:
${String(message || "").trim()}

Draft the GitHub issue title and Markdown body.`;

  const preferred = [
    requestedHarness === "claude-code" ? "claude-cli" : null,
    requestedHarness === "codex" ? "codex-cli" : null,
    "codex-cli",
    "claude-cli"
  ].filter(Boolean);
  const providers = preferred
    .map((id) => available.find((provider) => provider.id === id))
    .filter((provider, index, list) => provider && list.indexOf(provider) === index);
  const errors = [];
  for (const provider of providers) {
    try {
      const result = provider.id === "claude-cli"
        ? await draftGithubIssueWithClaude({ systemPrompt, schema: ISSUE_DRAFT_SCHEMA, userPrompt, cwd: workspace.path })
        : await provider.generateBlueprint({ systemPrompt, schema: ISSUE_DRAFT_SCHEMA, userPrompt, cwd: workspace.path });
      return {
        ...normalizeIssueDraft(result.structured_output, message),
        repo: binding ? `${binding.owner}/${binding.repo}` : "",
        provider: result.provider || provider.id
      };
    } catch (error) {
      errors.push(`${provider.id}: ${error.message}`);
    }
  }

  const error = new Error(`Could not draft issue with local agents. ${errors.join(" | ")}`);
  error.statusCode = 500;
  throw error;
}

async function draftGithubIssueWithClaude({ systemPrompt, schema, userPrompt, cwd }) {
  const args = [
    "-p", userPrompt,
    "--append-system-prompt", systemPrompt,
    "--output-format", "json",
    "--json-schema", JSON.stringify(schema),
    "--permission-mode", "dontAsk",
    "--allowedTools", "Read,Glob,Grep",
    "--add-dir", cwd,
    "--max-turns", "8"
  ];
  const { stdout } = await runCapture(CLAUDE_BIN, args, cwd, { timeout: 120_000 });
  const parsed = JSON.parse(stdout);
  const structuredOutput = firstParseableJsonObject([parsed.structured_output, parsed.result, parsed.response, parsed.content, stdout]);
  return {
    structured_output: structuredOutput?.structured_output || structuredOutput,
    cost_usd: parsed.total_cost_usd ?? null,
    duration_ms: parsed.duration_ms ?? null,
    model: parsed.model ?? null,
    provider: "claude-cli"
  };
}

async function createBlueprint(ticket, workspaceId, requestedHarness, { bypassCache = false } = {}) {
  const workspace = resolveWorkspace(workspaceId);
  fs.mkdirSync(BLUEPRINT_CACHE_DIR, { recursive: true });
  const cachePath = blueprintCachePath(ticket, workspace);
  if (!bypassCache) {
    try {
      const cached = JSON.parse(fs.readFileSync(cachePath, "utf8"));
      const blueprint = validateBlueprint(normalizeBlueprint(cached, ticket, workspace, cached.provider || cached._provider || "cache", {
        cached: true,
        cachePath,
        repoSha: cached.repoSha || cached._repo_sha,
        ticketHash: cached.ticketHash || cached._ticket_hash,
        costUsd: cached.costUsd ?? cached._cost_usd,
        durationMs: cached.durationMs ?? cached._duration_ms,
        model: cached.model || cached._model,
        usage: cached.usage || null
      }));
      plans.set(blueprint.id, blueprint);
      return blueprint;
    } catch {}
  }

  const providers = getPlanningProviderCandidates(requestedHarness);
  if (!providers.length) {
    throw new Error("No Blueprint provider is available. Install Claude Code or Codex CLI on this Mac.");
  }
  const { systemPrompt, schema, userPrompt } = renderBlueprintPrompt(ticket, workspace);
  const startedAt = Date.now();
  const errors = [];
  let result = null;
  let provider = null;
  for (const candidate of providers) {
    try {
      result = await candidate.generateBlueprint({
        systemPrompt,
        schema,
        userPrompt,
        cwd: workspace.path,
        ticket
      });
      provider = candidate;
      break;
    } catch (error) {
      errors.push(`${candidate.id}: ${error.message}`);
    }
  }
  if (!result || !provider) {
    result = {
      structured_output: inferBlueprintFromTicket(ticket),
      cost_usd: 0,
      duration_ms: Date.now() - startedAt,
      model: "local-heuristic",
      provider: "local-heuristic",
      providerErrors: errors
    };
    provider = { id: "local-heuristic" };
  }
  const blueprint = validateBlueprint(normalizeBlueprint(result.structured_output, ticket, workspace, result.provider || provider.id, {
    cached: false,
    cachePath,
    repoSha: repoHeadSha(workspace),
    ticketHash: ticketHash(ticket),
    costUsd: result.cost_usd,
    durationMs: result.duration_ms ?? Date.now() - startedAt,
    model: result.model,
    usage: result.usage || null
  }));
  const inferred = normalizeBlueprint(inferBlueprintFromTicket(ticket), ticket, workspace, "local-heuristic");
  if (!blueprint.files.length && inferred.files.length) {
    blueprint.files = inferred.files;
    blueprint.likelyFiles = inferred.likelyFiles;
    blueprint.blueprintConfidence = Math.max(blueprint.blueprintConfidence ?? 0, 0.72);
    blueprint.confidence = blueprint.blueprintConfidence;
  }
  if (!blueprint.riskAreas.length && inferred.riskAreas.length) {
    blueprint.riskAreas = inferred.riskAreas;
    blueprint.risks = inferred.risks;
  }
  // Surface a degraded blueprint honestly instead of letting the heuristic
  // fallback masquerade as a confident result (the old conf-0.72 problem).
  if ((result.provider || provider.id) === "local-heuristic") {
    blueprint.degraded = true;
    blueprint.degradedReason = "Full analysis didn't run; this is a rough estimate from the ticket text. Tap refresh to retry.";
  }
  fs.writeFileSync(cachePath, JSON.stringify({
    degraded: blueprint.degraded || false,
    degradedReason: blueprint.degradedReason || null,
    outcome: blueprint.outcome,
    missing_info: blueprint.missingInfo,
    summary: blueprint.summary,
    size: blueprint.size,
    files: blueprint.files,
    deps: blueprint.deps,
    migrations: blueprint.migrations,
    risk_areas: blueprint.riskAreas,
    out_of_scope: blueprint.outOfScope,
    open_questions: blueprint.openQuestions,
    default_agent: blueprint.defaultAgent,
    blueprint_confidence: blueprint.blueprintConfidence,
    tests: blueprint.tests,
    id: blueprint.id,
    createdAt: blueprint.createdAt,
    provider: blueprint.provider,
    repoSha: blueprint.repoSha,
    ticketHash: blueprint.ticketHash,
    costUsd: blueprint.costUsd,
    durationMs: blueprint.durationMs,
    model: blueprint.model,
    usage: blueprint.usage
  }, null, 2));
  try { fs.chmodSync(cachePath, 0o600); } catch {}
  plans.set(blueprint.id, blueprint);
  persistState();
  return blueprint;
}

async function createPlan(ticket, workspaceId, requestedHarness) {
  return createBlueprint(ticket, workspaceId, requestedHarness);
}

// ---------- Git branch / PR loop ----------

function gitRun(cwd, args, { timeout = 15_000 } = {}) {
  return spawnSync("git", ["-C", cwd, ...args], { timeout, encoding: "utf8" });
}

function setupBranchIfApplicable(session) {
  const binding = workspaceRepoBinding(session.workspace);
  if (!binding) {
    // Not a GitHub-bound repo: stay in plain mode silently.
    return;
  }

  // Require a clean tree before we branch. Surface a clear event if dirty
  // so the user understands why the PR loop didn't engage.
  const status = gitRun(session.workspace.path, ["status", "--porcelain"]);
  if (status.status !== 0) {
    addEvent(session, { type: "branch", kind: "skipped", text: "Could not read git status; skipping branch mode." });
    return;
  }
  if (status.stdout.trim()) {
    addEvent(session, {
      type: "branch",
      kind: "skipped",
      text: "Workspace has uncommitted changes; running in plain mode. Commit or stash, then dispatch again to get the PR loop."
    });
    return;
  }

  // Capture base branch so we can build the compare URL later.
  const head = gitRun(session.workspace.path, ["rev-parse", "--abbrev-ref", "HEAD"]);
  if (head.status !== 0) {
    addEvent(session, { type: "branch", kind: "skipped", text: "Could not read current branch; skipping branch mode." });
    return;
  }
  const baseBranch = head.stdout.trim();

  // Branch name: loupe/<ticket-slug-or-task-id>. Keep it short and uniqueness-safe.
  const slug = session.dispatch?.ticket
    ? `${session.dispatch.ticket.repo.split("/")[1]}-${session.dispatch.ticket.number}-${session.id.split("-").slice(-1)[0]}`
    : `task-${session.id.split("-").slice(-2).join("-")}`;
  const branchName = `loupe/${slug}`.toLowerCase().replace(/[^a-z0-9/_-]+/g, "-");

  const checkout = gitRun(session.workspace.path, ["checkout", "-b", branchName]);
  if (checkout.status !== 0) {
    addEvent(session, {
      type: "branch",
      kind: "error",
      text: `Could not create branch ${branchName}: ${(checkout.stderr || "").trim().slice(0, 300)}`
    });
    return;
  }

  session.branch = { name: branchName, base: baseBranch, binding };
  addEvent(session, {
    type: "branch",
    kind: "created",
    branch: branchName,
    base: baseBranch,
    repo: `${binding.owner}/${binding.repo}`,
    text: `Branched ${branchName} from ${baseBranch}.`
  });
}

async function finalizeBranch(session) {
  const { name: branch, base, binding } = session.branch;
  const cwd = session.workspace.path;

  // 1. Stage everything the agent touched.
  const add = gitRun(cwd, ["add", "-A"]);
  if (add.status !== 0) {
    throw new Error(`git add failed: ${(add.stderr || "").trim()}`);
  }

  // 2. Check whether anything actually changed. If not, abandon the branch
  //    cleanly instead of pushing an empty branch.
  const diff = gitRun(cwd, ["diff", "--cached", "--quiet"]);
  if (diff.status === 0) {
    addEvent(session, {
      type: "branch",
      kind: "no_changes",
      branch,
      text: `Agent finished but made no file changes. Branch ${branch} not pushed.`
    });
    // Switch back to base so the workspace is clean for the next dispatch.
    gitRun(cwd, ["checkout", base]);
    gitRun(cwd, ["branch", "-D", branch]);
    return;
  }
  const changedFiles = changedFilesFromCachedDiff(cwd);
  const handoff = buildSessionHandoff(session, changedFiles);
  const deviation = compareBlueprintHandoff(session.dispatch?.plan, changedFiles, handoff);
  session.deviation = deviation;
  addEvent(session, { type: "handoff", kind: "ready", handoff });
  addEvent(session, { type: "deviations_computed", deviation });

  // 3. Commit. Subject line from the ticket / first message line.
  const subject = (session.dispatch?.ticket?.title || session.message.split(/\r?\n/)[0] || "Loupe agent change").slice(0, 72);
  const trailer = session.dispatch?.ticket?.url ? `\n\nRefs: ${session.dispatch.ticket.url}` : "";
  const commitMsg = `loupe: ${subject}${trailer}\n\n[via ${session.harnessId} · session ${session.id}]`;
  const commit = gitRun(cwd, ["commit", "-m", commitMsg]);
  if (commit.status !== 0) {
    throw new Error(`git commit failed: ${(commit.stderr || "").trim()}`);
  }
  const commitSha = gitRun(cwd, ["rev-parse", "HEAD"]).stdout.trim();
  addEvent(session, { type: "branch", kind: "committed", branch, sha: commitSha, subject });

  // 4. Push. This relies on the user's existing git credential helper.
  const push = gitRun(cwd, ["push", "-u", "origin", branch], { timeout: 45_000 });
  if (push.status !== 0) {
    const reason = (push.stderr || push.stdout || "").trim().slice(0, 600);
    addEvent(session, {
      type: "branch",
      kind: "push_failed",
      branch,
      text: `Pushed locally; remote push failed. Run \`git -C ${cwd} push -u origin ${branch}\` to retry.\n\n${reason}`
    });
    return;
  }

  const finalPrBody = formatPrBody(session, handoff, { branch, base, commitSha });

  // 5. Create a draft PR when GitHub auth is configured. If that fails, fall
  // back to the compare URL so the user can still finish in GitHub Mobile.
  const compareUrl = `https://${binding.host}/${binding.owner}/${binding.repo}/compare/${encodeURIComponent(base)}...${encodeURIComponent(branch)}?expand=1`;
  let prUrl = null;
  let prNumber = null;
  let prError = null;
  const token = getGithubAccessToken();
  if (token && binding.host === "github.com") {
    try {
      const pr = await githubApiRequest("POST", `/repos/${encodeURIComponent(binding.owner)}/${encodeURIComponent(binding.repo)}/pulls`, token, {
        title: `loupe: ${subject}`,
        head: branch,
        base,
        body: finalPrBody,
        draft: true
      });
      prUrl = pr.html_url;
      prNumber = pr.number;
    } catch (error) {
      prError = error.message;
      addEvent(session, { type: "branch", kind: "pr_failed", branch, text: `Could not create draft PR automatically. Use the compare URL instead.\n\n${prError}` });
    }
  } else if (!token) {
    prError = "GitHub OAuth is not connected; created compare URL instead.";
  }

  addEvent(session, {
    type: "branch",
    kind: "pr_ready",
    branch,
    base,
    repo: `${binding.owner}/${binding.repo}`,
    sha: commitSha,
    prUrl,
    prNumber,
    compareUrl,
    handoff,
    text: prUrl
      ? `Draft PR #${prNumber} is ready in ${binding.owner}/${binding.repo}.`
      : `Pushed ${branch} to ${binding.owner}/${binding.repo}. Tap to open the PR draft.${prError ? ` ${prError}` : ""}`
  });
}

function spawnCodex(session, message, { resume = false } = {}) {
  const args = resume
    ? [
        "exec",
        "--json",
        "--sandbox",
        "workspace-write",
        "--skip-git-repo-check",
        "-C",
        session.workspace.path,
        "resume",
        session.codexThreadId,
        message
      ]
    : [
        "exec",
        "--json",
        "--sandbox",
        "workspace-write",
        "--skip-git-repo-check",
        "-C",
        session.workspace.path,
        message
      ];

  addEvent(session, {
    type: "command",
    text: `${CODEX_BIN} ${args.map((arg) => (arg.includes(" ") ? JSON.stringify(arg) : arg)).join(" ")}`
  });

  const child = spawn(CODEX_BIN, args, {
    cwd: session.workspace.path,
    env: { ...process.env, NO_COLOR: "1" },
    stdio: ["ignore", "pipe", "pipe"]
  });

  let stdoutBuffer = "";
  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString();
    const lines = stdoutBuffer.split(/\r?\n/);
    stdoutBuffer = lines.pop() || "";
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const payload = JSON.parse(line);
        if (payload.type === "thread.started" && payload.thread_id) {
          session.codexThreadId = payload.thread_id;
        }
        if (payload.item?.type === "agent_message" && payload.item.text) {
          noteAgentMessage(session, payload.item.text);
        }
        addEvent(session, { type: "codex", payload });
      } catch {
        addEvent(session, { type: "stdout", text: line });
      }
    }
  });

  child.stderr.on("data", (chunk) => {
    addEvent(session, { type: "stderr", text: chunk.toString() });
  });

  session._flushStdout = () => {
    if (stdoutBuffer.trim()) {
      addEvent(session, { type: "stdout", text: stdoutBuffer.trim() });
      stdoutBuffer = "";
    }
  };

  return child;
}

function spawnClaudeCode(session, message, { resume = false } = {}) {
  // --permission-mode acceptEdits auto-allows file writes + safe filesystem commands.
  // --allowedTools "Bash" extends that to arbitrary shell, matching Codex's workspace-write scope.
  // --add-dir ensures the workspace is in the allowed-roots set for fresh phone-created folders.
  const args = [
    "-p",
    message,
    "--output-format", "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--model", executionModelAlias(),
    "--permission-mode", "acceptEdits",
    "--allowedTools", "Bash,WebFetch",
    "--add-dir", session.workspace.path
  ];
  if (resume) {
    args.push("--resume", session.claudeSessionId);
  }

  addEvent(session, {
    type: "command",
    text: `${CLAUDE_BIN} ${args.map((arg) => (arg.includes(" ") ? JSON.stringify(arg) : arg)).join(" ")}`
  });

  const child = spawn(CLAUDE_BIN, args, {
    cwd: session.workspace.path,
    env: { ...process.env, NO_COLOR: "1", FORCE_COLOR: "0" },
    stdio: ["ignore", "pipe", "pipe"]
  });

  let stdoutBuffer = "";
  // Accumulator for streaming text deltas so we can re-emit consolidated messages
  // on partial-message boundaries (better UX than per-token chips).
  const deltaState = { text: "", messageId: null };

  function flushDelta() {
    if (deltaState.text.trim()) {
      noteAgentMessage(session, deltaState.text);
      addEvent(session, { type: "claude", kind: "message", text: deltaState.text, messageId: deltaState.messageId });
    }
    deltaState.text = "";
    deltaState.messageId = null;
  }

  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString();
    const lines = stdoutBuffer.split(/\r?\n/);
    stdoutBuffer = lines.pop() || "";
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        handleClaudeLine(session, JSON.parse(line), deltaState, flushDelta);
      } catch {
        addEvent(session, { type: "stdout", text: line });
      }
    }
  });

  child.stderr.on("data", (chunk) => {
    addEvent(session, { type: "stderr", text: chunk.toString() });
  });

  session._flushStdout = () => {
    flushDelta();
    if (stdoutBuffer.trim()) {
      addEvent(session, { type: "stdout", text: stdoutBuffer.trim() });
      stdoutBuffer = "";
    }
  };

  return child;
}

function handleClaudeLine(session, payload, deltaState, flushDelta) {
  // Claude stream-json schema: every line is a typed event.
  // We normalize into { type: "claude", kind: ..., ... } shapes the PWA understands.
  // Drop internal lifecycle noise that has no UI meaning.
  if (payload.type === "system" && ["hook_started", "hook_response", "status", "plugin_install"].includes(payload.subtype)) {
    return;
  }

  if (payload.type === "system" && payload.subtype === "init") {
    if (payload.session_id) session.claudeSessionId = payload.session_id;
    addEvent(session, {
      type: "claude",
      kind: "thread_start",
      sessionId: payload.session_id,
      model: payload.model,
      tools: payload.tools
    });
    return;
  }

  if (payload.type === "system" && payload.subtype === "api_retry") {
    addEvent(session, {
      type: "claude",
      kind: "retry",
      attempt: payload.attempt,
      maxRetries: payload.max_retries,
      retryDelayMs: payload.retry_delay_ms,
      error: payload.error
    });
    return;
  }

  if (payload.type === "stream_event") {
    const event = payload.event || {};
    // Text deltas come through repeatedly; accumulate and emit on message_stop.
    if (event.type === "content_block_delta" && event.delta?.type === "text_delta" && event.delta.text) {
      deltaState.text += event.delta.text;
      return;
    }
    if (event.type === "message_stop") {
      flushDelta();
      return;
    }
    return;
  }

  if (payload.type === "assistant") {
    flushDelta();
    const blocks = payload.message?.content || [];
    for (const block of blocks) {
      if (block.type === "tool_use") {
        const inputPreview = previewToolInput(block.name, block.input);
        addEvent(session, {
          type: "claude",
          kind: "tool_use",
          toolName: block.name,
          toolUseId: block.id,
          input: inputPreview
        });
        // Surface Edit/Write/MultiEdit as file changes too so they show up in the files tab.
        const filePath = block.input?.file_path || block.input?.path;
        if (filePath && ["Edit", "Write", "MultiEdit", "NotebookEdit"].includes(block.name)) {
          addEvent(session, {
            type: "claude",
            kind: "file_change",
            path: filePath,
            changeKind: block.name.toLowerCase()
          });
        }
      } else if (block.type === "text" && block.text) {
        // Non-streaming text (rare with --include-partial-messages but possible)
        noteAgentMessage(session, block.text);
        addEvent(session, { type: "claude", kind: "message", text: block.text });
      }
    }
    return;
  }

  if (payload.type === "user") {
    const blocks = payload.message?.content || [];
    for (const block of blocks) {
      if (block.type === "tool_result") {
        const content = block.content;
        const text = typeof content === "string"
          ? content
          : Array.isArray(content)
            ? content.map((c) => c.text || "").join("\n")
            : JSON.stringify(content);
        addEvent(session, {
          type: "claude",
          kind: "tool_result",
          toolUseId: block.tool_use_id,
          output: text.slice(0, 4000),
          isError: !!block.is_error
        });
      }
    }
    return;
  }

  if (payload.type === "result") {
    flushDelta();
    if (payload.result) noteAgentMessage(session, payload.result);
    addEvent(session, {
      type: "claude",
      kind: "result",
      result: payload.result || "",
      isError: !!payload.is_error,
      durationMs: payload.duration_ms,
      numTurns: payload.num_turns,
      totalCostUsd: payload.total_cost_usd,
      usage: payload.usage
    });
    return;
  }

  // Unknown event type — keep raw for debugging.
  addEvent(session, { type: "claude", kind: "unknown", payload });
}

function previewToolInput(toolName, input) {
  if (!input) return "";
  // Compact, human-readable preview for the actions tab.
  if (toolName === "Bash" && input.command) return input.command;
  if ((toolName === "Edit" || toolName === "MultiEdit") && input.file_path) return input.file_path;
  if (toolName === "Write" && input.file_path) return input.file_path;
  if (toolName === "Read" && input.file_path) return input.file_path;
  if (toolName === "Glob" && input.pattern) return input.pattern;
  if (toolName === "Grep" && input.pattern) return `${input.pattern}${input.path ? ` in ${input.path}` : ""}`;
  if (toolName === "WebFetch" && input.url) return input.url;
  try {
    const json = JSON.stringify(input);
    return json.length > 200 ? `${json.slice(0, 200)}...` : json;
  } catch {
    return String(input);
  }
}

function serveStatic(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const requested = url.pathname === "/" ? "/index.html" : decodeURIComponent(url.pathname);
  const filePath = path.normalize(path.join(ROOT, requested));

  if (!filePath.startsWith(ROOT)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }

  fs.readFile(filePath, (error, content) => {
    if (error) {
      res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
      res.end("Not found");
      return;
    }
    res.writeHead(200, {
      "content-type": mimeTypes[path.extname(filePath)] || "application/octet-stream",
      "cache-control": "no-store"
    });
    res.end(content);
  });
}

hydrateState();

const server = http.createServer(async (req, res) => {
  recordRequest(req);
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "content-type,x-loupe-token,authorization"
    });
    res.end();
    return;
  }

  if (url.pathname.startsWith("/api/") && !isPublicApi(url.pathname) && !isAuthorized(req, url)) {
    sendJson(res, 401, {
      ok: false,
      authRequired: true,
      error: "Loupe is not paired with this browser. Open the pairing URL printed by the Mac daemon."
    });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/pairing/status") {
    sendJson(res, 200, {
      ok: true,
      authRequired: true,
      paired: isAuthorized(req, url),
      tokenPreview: tokenPreview(config.apiToken)
    });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/v1/pairing/devices") {
    ensureDeviceRegistry();
    sendJson(res, 200, { ok: true, data: configSummary().devices });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/v1/pairing/rotate") {
    const now = new Date().toISOString();
    for (const device of config.devices || []) {
      device.revokedAt = device.revokedAt || now;
    }
    config.apiToken = createSecretToken();
    config.devices = [{
      id: `device-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
      name: "Rotated pairing token",
      tokenHash: hashToken(config.apiToken),
      createdAt: now,
      lastSeenAt: null,
      lastIp: null,
      revokedAt: null
    }];
    saveConfig();
    sendJson(res, 200, { ok: true, data: { tokenPreview: tokenPreview(config.apiToken), pairingUrls: getPairingUrls() } });
    return;
  }

  if (req.method === "DELETE" && url.pathname.match(/^\/api\/v1\/pairing\/devices\/[^/]+$/)) {
    const id = decodeURIComponent(url.pathname.split("/").pop() || "");
    const device = (config.devices || []).find((item) => item.id === id);
    if (device) {
      device.revokedAt = new Date().toISOString();
      saveConfig();
    }
    sendJson(res, 200, { ok: true, data: configSummary().devices });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/health") {
    sendJson(res, 200, {
      ok: true,
      daemon: "loupe-mac-daemon",
      codexBin: CODEX_BIN,
      claudeBin: CLAUDE_BIN,
      harnesses: harnessRegistry,
      defaultHarness: defaultHarnessId(),
      cwd: ROOT,
      sessions: sessions.size,
      urls: getNetworkUrls(),
      workspaces,
      workspaceBindings: listWorkspaceBindings(),
      workspaceReadiness: listWorkspaceReadiness(),
      fsRoots: getFsRoots(),
      codexUsage: getCodexUsage(),
      claudeUsage: getClaudeUsage(),
      recentRequests,
      config: configSummary()
    });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/v1/inbox") {
    try {
      const token = getGithubAccessToken();
      if (!token) {
        sendJson(res, 401, { ok: false, error: { code: "GITHUB_AUTH_REQUIRED", message: "Connect GitHub first.", retryable: false } });
        return;
      }
      const payload = await fetchGithubInbox(token);
      inboxCache.fetchedAt = Date.now();
      inboxCache.payload = payload;
      sendJson(res, 200, { ok: true, data: payload, error: null });
    } catch (error) {
      sendJson(res, error.statusCode || 500, { ok: false, data: null, error: { code: "INBOX_FAILED", message: error.message, retryable: true } });
    }
    return;
  }

  const prDetailMatch = url.pathname.match(/^\/api\/v1\/prs\/([^/]+)\/([^/]+)\/(\d+)$/);
  if (req.method === "GET" && prDetailMatch) {
    try {
      const pr = await fetchPullRequestDetail(decodeURIComponent(prDetailMatch[1]), decodeURIComponent(prDetailMatch[2]), prDetailMatch[3]);
      sendJson(res, 200, { ok: true, data: pr, error: null });
    } catch (error) {
      sendJson(res, error.statusCode || 500, { ok: false, data: null, error: { code: "PR_DETAIL_FAILED", message: error.message, retryable: true } });
    }
    return;
  }

  const prActionMatch = url.pathname.match(/^\/api\/v1\/prs\/([^/]+)\/([^/]+)\/(\d+)\/(review|merge|reject)$/);
  if (req.method === "POST" && prActionMatch) {
    try {
      const owner = decodeURIComponent(prActionMatch[1]);
      const repo = decodeURIComponent(prActionMatch[2]);
      const number = Number(prActionMatch[3]);
      const action = prActionMatch[4];
      const body = JSON.parse(await readBody(req) || "{}");
      if (action === "review") {
        const event = body.event === "REQUEST_CHANGES" ? "REQUEST_CHANGES" : "APPROVE";
        const review = await submitPullRequestReview(owner, repo, number, { event, body: body.body || (event === "APPROVE" ? "Approved from Loupe." : "Changes requested from Loupe.") });
        sendJson(res, 200, { ok: true, data: { review }, error: null });
        return;
      }
      if (action === "merge") {
        const result = await mergePullRequest(owner, repo, number, {
          commitTitle: body.commitTitle,
          commitMessage: body.commitMessage
        });
        sendJson(res, 200, { ok: true, data: result, error: null });
        return;
      }
      const reason = String(body.reason || "").trim();
      if (!reason) {
        sendJson(res, 400, { ok: false, data: null, error: { code: "REJECT_REASON_REQUIRED", message: "Reject requires a reason.", retryable: false } });
        return;
      }
      const review = await submitPullRequestReview(owner, repo, number, { event: "REQUEST_CHANGES", body: reason });
      const closed = body.close === false ? null : await closePullRequest(owner, repo, number);
      sendJson(res, 200, { ok: true, data: { review, closed }, error: null });
    } catch (error) {
      sendJson(res, error.statusCode || 500, { ok: false, data: null, error: { code: "PR_ACTION_FAILED", message: error.message, retryable: true } });
    }
    return;
  }

  const sendBackMatch = url.pathname.match(/^\/api\/v1\/sessions\/([^/]+)\/send-back$/);
  if (req.method === "POST" && sendBackMatch) {
    try {
      const id = decodeURIComponent(sendBackMatch[1]);
      const body = JSON.parse(await readBody(req) || "{}");
      const feedback = String(body.feedback || "").trim();
      if (!feedback) {
        sendJson(res, 400, { ok: false, data: null, error: { code: "FEEDBACK_REQUIRED", message: "Send back requires feedback.", retryable: false } });
        return;
      }
      const prLabel = body.pr ? `${body.pr.repo || ""}#${body.pr.number || ""}` : "this PR";
      const prompt = `Reviewer feedback for ${prLabel}:\n\n${feedback}\n\nUse the existing branch. Make only the requested changes. Update the HANDOFF JSON at the end. Do not merge or close the PR.`;
      const session = continueSession(id, prompt);
      sendJson(res, 200, { ok: true, data: { sessionId: session.id, status: session.status }, error: null });
    } catch (error) {
      sendJson(res, error.statusCode || 500, { ok: false, data: null, error: { code: "SEND_BACK_FAILED", message: error.message, retryable: true } });
    }
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/sessions") {
    const serialized = [...sessions.values()]
      .map(serializeSession)
      .sort((a, b) => String(b.startedAt || "").localeCompare(String(a.startedAt || "")));
    sendJson(res, 200, { ok: true, sessions: serialized });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/github/oauth/start") {
    try {
      if (!GITHUB_OAUTH_CLIENT_ID) {
        sendJson(res, 400, {
          ok: false,
          error: "GitHub OAuth client ID is not configured. Start the daemon with GITHUB_OAUTH_CLIENT_ID."
        });
        return;
      }
      cleanupGithubOAuthFlows();
      const payload = await githubOAuthPost("/login/device/code", {
        client_id: GITHUB_OAUTH_CLIENT_ID,
        scope: GITHUB_OAUTH_SCOPES
      });
      const flowId = createSecretToken();
      const interval = Math.max(5, Number(payload.interval) || 5);
      githubOAuthFlows.set(flowId, {
        deviceCode: payload.device_code,
        userCode: payload.user_code,
        verificationUri: payload.verification_uri,
        expiresAt: Date.now() + (Number(payload.expires_in) || 900) * 1000,
        interval,
        lastPollAt: 0
      });
      sendJson(res, 200, {
        ok: true,
        flowId,
        userCode: payload.user_code,
        verificationUri: payload.verification_uri,
        expiresIn: Number(payload.expires_in) || 900,
        interval,
        scope: GITHUB_OAUTH_SCOPES
      });
    } catch (error) {
      sendJson(res, error.statusCode || 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/github/oauth/poll") {
    try {
      const body = JSON.parse(await readBody(req) || "{}");
      const flowId = String(body.flowId || "");
      const flow = githubOAuthFlows.get(flowId);
      if (!flow) {
        sendJson(res, 404, { ok: false, status: "expired", error: "OAuth flow expired. Start GitHub connect again." });
        return;
      }
      if (flow.expiresAt <= Date.now()) {
        githubOAuthFlows.delete(flowId);
        sendJson(res, 400, { ok: false, status: "expired", error: "GitHub code expired. Start GitHub connect again." });
        return;
      }
      const elapsed = Date.now() - flow.lastPollAt;
      if (flow.lastPollAt && elapsed < flow.interval * 1000) {
        sendJson(res, 202, {
          ok: false,
          status: "waiting",
          interval: flow.interval,
          waitSeconds: Math.ceil((flow.interval * 1000 - elapsed) / 1000)
        });
        return;
      }
      flow.lastPollAt = Date.now();
      const tokenPayload = await githubOAuthPost("/login/oauth/access_token", {
        client_id: GITHUB_OAUTH_CLIENT_ID,
        device_code: flow.deviceCode,
        grant_type: "urn:ietf:params:oauth:grant-type:device_code"
      });

      if (tokenPayload.error === "authorization_pending") {
        sendJson(res, 202, { ok: false, status: "pending", interval: flow.interval });
        return;
      }
      if (tokenPayload.error === "slow_down") {
        flow.interval += 5;
        sendJson(res, 202, { ok: false, status: "pending", interval: flow.interval });
        return;
      }
      if (tokenPayload.error) {
        githubOAuthFlows.delete(flowId);
        sendJson(res, 400, { ok: false, status: tokenPayload.error, error: tokenPayload.error_description || tokenPayload.error });
        return;
      }
      if (!tokenPayload.access_token) {
        throw new Error("GitHub did not return an access token.");
      }

      const viewer = await githubRequest("/user", tokenPayload.access_token);
      saveGithubOAuth(tokenPayload, viewer);
      githubOAuthFlows.delete(flowId);
      sendJson(res, 200, { ok: true, status: "authorized", login: viewer.login, config: configSummary() });
    } catch (error) {
      sendJson(res, error.statusCode || 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/github/disconnect") {
    clearGithubAuth();
    sendJson(res, 200, { ok: true, config: configSummary() });
    return;
  }

  if (req.method === "POST" && (url.pathname === "/api/plans/create" || url.pathname === "/api/blueprints/create")) {
    try {
      const body = JSON.parse(await readBody(req) || "{}");
      const ticket = body.ticket || {};
      if (!ticket.title && !ticket.body) {
        sendJson(res, 400, { ok: false, error: "Ticket title or body is required to create a Blueprint." });
        return;
      }
      const blueprint = await createBlueprint(ticket, body.workspaceId, body.harness, { bypassCache: body.refresh === true });
      const publicPlan = publicBlueprint(blueprint);
      sendJson(res, 200, { ok: true, blueprint: publicPlan, plan: publicPlan });
    } catch (error) {
      sendJson(res, error.statusCode || 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && ["/api/github/issues/draft", "/api/github/issues/draft/", "/api/v1/github/issues/draft"].includes(url.pathname)) {
    try {
      const body = JSON.parse(await readBody(req) || "{}");
      const message = String(body.message || "").trim();
      if (!message) {
        sendJson(res, 400, { ok: false, error: "Message is required to draft an issue." });
        return;
      }
      console.log(`Drafting GitHub issue via ${body.harness || "default"} for ${body.workspaceId || "default workspace"}`);
      const draft = await draftGithubIssue({
        message,
        workspaceId: body.workspaceId,
        requestedHarness: body.harness
      });
      sendJson(res, 200, { ok: true, draft });
    } catch (error) {
      sendJson(res, error.statusCode || 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/config/github") {
    try {
      const body = JSON.parse(await readBody(req) || "{}");
      const token = String(body.token || "").trim();
      if (!token) {
        // Clearing the token is allowed — null it out.
        clearGithubAuth();
        sendJson(res, 200, { ok: true, cleared: true, config: configSummary() });
        return;
      }
      // Probe the token before persisting so we don't save garbage.
      const viewer = await githubRequest("/user", token);
      config.githubToken = token;
      config.githubLogin = viewer.login;
      saveConfig();
      inboxCache.fetchedAt = 0;
      inboxCache.payload = null;
      sendJson(res, 200, { ok: true, login: viewer.login, config: configSummary() });
    } catch (error) {
      sendJson(res, 400, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/github/inbox") {
    try {
      const token = getGithubAccessToken();
      if (!token) {
        sendJson(res, 400, { ok: false, error: "GitHub is not connected. Connect GitHub with OAuth first." });
        return;
      }
      const force = url.searchParams.get("refresh") === "1";
      const fresh = inboxCache.payload && (Date.now() - inboxCache.fetchedAt) < inboxCache.ttlMs;
      if (!force && fresh) {
        sendJson(res, 200, { ok: true, cached: true, ...inboxCache.payload });
        return;
      }
      const payload = await fetchGithubInbox(token);
      inboxCache.fetchedAt = Date.now();
      inboxCache.payload = payload;
      sendJson(res, 200, { ok: true, cached: false, ...payload });
    } catch (error) {
      sendJson(res, error.statusCode || 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/github/issues") {
    try {
      const body = JSON.parse(await readBody(req) || "{}");
      const issue = await createGithubIssue({
        repoFullName: body.repo,
        title: body.title,
        body: body.body,
        assignSelf: body.assignSelf !== false
      });
      sendJson(res, 201, { ok: true, issue });
    } catch (error) {
      sendJson(res, error.statusCode || 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/fs/list") {
    try {
      sendJson(res, 200, { ok: true, ...listFolders(url.searchParams.get("path")) });
    } catch (error) {
      sendJson(res, 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/workspaces/create") {
    try {
      const body = JSON.parse(await readBody(req) || "{}");
      const parentPath = path.resolve(String(body.parentPath || os.homedir()));
      const folderName = cleanFolderName(body.name);
      const workspacePath = path.join(parentPath, folderName);
      fs.mkdirSync(workspacePath, { recursive: true });
      const workspace = addWorkspace(workspacePath);
      sendJson(res, 200, {
        ok: true,
        workspace,
        workspaces
      });
    } catch (error) {
      sendJson(res, 500, { ok: false, error: error.message });
    }
    return;
  }

  // New unified endpoint — body: { message, workspaceId, harness, dispatch }
  // /api/codex/start kept as alias for any cached PWA clients still in flight.
  if (req.method === "POST" && (url.pathname === "/api/sessions/start" || url.pathname === "/api/codex/start")) {
    try {
      const body = JSON.parse(await readBody(req) || "{}");
      const message = String(body.message || "").trim();
      if (!message) {
        sendJson(res, 400, { ok: false, error: "Message is required." });
        return;
      }
      const session = createSession(message, body.workspaceId, body.harness, body.dispatch);
      sendJson(res, 200, {
        ok: true,
        sessionId: session.id,
        status: session.status,
        harness: session.harnessId,
        workspace: session.workspace,
        branch: session.branch ? { name: session.branch.name, base: session.branch.base, repo: `${session.branch.binding.owner}/${session.branch.binding.repo}` } : null
      });
    } catch (error) {
      sendJson(res, 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname.match(/^\/api\/sessions\/[^/]+\/messages$/)) {
    try {
      const id = decodeURIComponent(url.pathname.split("/")[3] || "");
      const body = JSON.parse(await readBody(req) || "{}");
      const message = String(body.message || "").trim();
      if (!message) {
        sendJson(res, 400, { ok: false, error: "Message is required." });
        return;
      }
      const session = continueSession(id, message);
      sendJson(res, 200, {
        ok: true,
        sessionId: session.id,
        status: session.status,
        harness: session.harnessId,
        workspace: session.workspace,
        eventCount: session.events.length
      });
    } catch (error) {
      sendJson(res, error.statusCode || 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "GET" && (url.pathname.startsWith("/api/sessions/events/") || url.pathname.startsWith("/api/codex/events/"))) {
    const id = decodeURIComponent(url.pathname.split("/").pop() || "");
    const session = sessions.get(id);
    if (!session) {
      sendJson(res, 404, { ok: false, error: "Unknown session." });
      return;
    }
    res.writeHead(200, {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache, no-transform",
      connection: "keep-alive",
      "access-control-allow-origin": "*"
    });
    const since = Math.max(0, Number(url.searchParams.get("since")) || 0);
    for (const event of session.events.filter((item) => (item.id ?? 0) >= since)) {
      res.write(`data: ${JSON.stringify(event)}\n\n`);
    }
    session.clients.add(res);
    req.on("close", () => session.clients.delete(res));
    return;
  }

  serveStatic(req, res);
});

function startServer() {
  server.listen(PORT, HOST, () => {
    console.log(`Loupe Mac daemon listening on http://${HOST}:${PORT}`);
    console.log("Harnesses detected:");
    for (const harness of harnessRegistry) {
      const status = harness.available ? `OK   (${harness.version || "version unknown"})` : "MISSING";
      console.log(`  ${harness.id.padEnd(12)} ${status}`);
      if (harness.bin) console.log(`               ${harness.bin}`);
    }
    console.log(`Default harness: ${defaultHarnessId()}`);
    console.log("Open from this Mac or iPhone:");
    for (const url of getNetworkUrls()) {
      console.log(`  ${url}`);
    }
    console.log("Pair a browser once (treat like a password):");
    for (const url of getPairingUrls()) {
      console.log(`  ${url}`);
    }
    // Scan-to-pair QR for the LAN URL immediately; the tunnel prints its own
    // QR once it connects.
    console.log("\nScan to pair this phone:");
    renderQr(getPrimaryPairingUrl());
    startTunnel();
  });
}

if (require.main === module) {
  startServer();
}

module.exports = {
  createBlueprint,
  createPlan,
  normalizeBlueprint,
  validateBlueprint,
  compareBlueprintHandoff,
  renderBlueprintPrompt,
  ticketHash,
  repoHeadSha,
  workspaceReadiness,
  startServer
};
