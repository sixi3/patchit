const http = require("http");
const https = require("https");
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

const sessions = new Map();
const recentRequests = [];
const workspaces = getConfiguredWorkspaces();
const harnessRegistry = buildHarnessRegistry();
let config = loadConfig();
// Cache the GitHub inbox briefly so the PWA can re-render without hammering the API.
const inboxCache = { fetchedAt: 0, ttlMs: 60_000, payload: null };

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

function configSummary() {
  return {
    github: {
      configured: !!config.githubToken,
      login: config.githubLogin || null
    }
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

// ---------- GitHub API ----------
// Minimal HTTPS-only client. Uses search/issues so we can scope to assignee:@me
// across every repo the token can see in one call, then enriches with PR review
// requests in a second call. Enough for the demo inbox.

function githubRequest(pathname, token) {
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: "api.github.com",
      path: pathname,
      method: "GET",
      headers: {
        "user-agent": "loupe-mac-daemon",
        accept: "application/vnd.github+json",
        "x-github-api-version": "2022-11-28",
        authorization: `Bearer ${token}`
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
    req.end();
  });
}

async function fetchGithubInbox(token) {
  // Two queries, one assignee one review-requested. Search API supports both.
  const [assignedIssues, reviewRequests, viewer] = await Promise.all([
    githubRequest(`/search/issues?q=${encodeURIComponent("assignee:@me is:open archived:false")}&per_page=30&sort=updated`, token),
    githubRequest(`/search/issues?q=${encodeURIComponent("is:pr is:open review-requested:@me archived:false")}&per_page=30&sort=updated`, token),
    githubRequest("/user", token)
  ]);

  // Persist login on first fetch so we can show it in config summary.
  if (viewer?.login && config.githubLogin !== viewer.login) {
    config.githubLogin = viewer.login;
    saveConfig();
  }

  const bindings = listWorkspaceBindings();
  function bindingFor(repoFullName) {
    if (!repoFullName) return null;
    const [owner, repo] = repoFullName.split("/");
    return bindings.find((b) => b.owner.toLowerCase() === owner.toLowerCase() && b.repo.toLowerCase() === repo.toLowerCase()) || null;
  }

  function normalize(item, kind) {
    // search/issues returns issues and PRs together; pull_request is non-null for PRs.
    const repoFullName = (item.repository_url || "").replace("https://api.github.com/repos/", "");
    return {
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
      binding: bindingFor(repoFullName)
    };
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

const mimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".md": "text/markdown; charset=utf-8"
};

function getNetworkUrls() {
  const interfaces = os.networkInterfaces();
  const urls = [`http://localhost:${PORT}/index.html`];

  for (const entries of Object.values(interfaces)) {
    for (const entry of entries || []) {
      if (entry.family === "IPv4" && !entry.internal) {
        urls.push(`http://${entry.address}:${PORT}/index.html`);
      }
    }
  }

  return urls;
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
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "access-control-allow-origin": "*"
  });
  res.end(JSON.stringify(payload));
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
    branch: null // populated by setupBranchIfApplicable when branch mode triggers
  };
  sessions.set(id, session);

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

  spawnSessionTurn(session, message, { resume: true });
  return session;
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

  // 5. Build the compare URL — opens GitHub's "Open a pull request" page on web/mobile.
  const compareUrl = `https://${binding.host}/${binding.owner}/${binding.repo}/compare/${encodeURIComponent(base)}...${encodeURIComponent(branch)}?expand=1`;
  addEvent(session, {
    type: "branch",
    kind: "pr_ready",
    branch,
    base,
    repo: `${binding.owner}/${binding.repo}`,
    sha: commitSha,
    compareUrl,
    text: `Pushed ${branch} to ${binding.owner}/${binding.repo}. Tap to open the PR draft.`
  });
}

function spawnCodex(session, message, { resume = false } = {}) {
  const args = resume
    ? [
        "exec",
        "resume",
        "--json",
        "--skip-git-repo-check",
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

const server = http.createServer(async (req, res) => {
  recordRequest(req);
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "content-type"
    });
    res.end();
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
      fsRoots: getFsRoots(),
      codexUsage: getCodexUsage(),
      claudeUsage: getClaudeUsage(),
      recentRequests,
      config: configSummary()
    });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/config/github") {
    try {
      const body = JSON.parse(await readBody(req) || "{}");
      const token = String(body.token || "").trim();
      if (!token) {
        // Clearing the token is allowed — null it out.
        delete config.githubToken;
        delete config.githubLogin;
        saveConfig();
        inboxCache.fetchedAt = 0;
        inboxCache.payload = null;
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
      if (!config.githubToken) {
        sendJson(res, 400, { ok: false, error: "GitHub token not configured. POST a token to /api/config/github." });
        return;
      }
      const force = url.searchParams.get("refresh") === "1";
      const fresh = inboxCache.payload && (Date.now() - inboxCache.fetchedAt) < inboxCache.ttlMs;
      if (!force && fresh) {
        sendJson(res, 200, { ok: true, cached: true, ...inboxCache.payload });
        return;
      }
      const payload = await fetchGithubInbox(config.githubToken);
      inboxCache.fetchedAt = Date.now();
      inboxCache.payload = payload;
      sendJson(res, 200, { ok: true, cached: false, ...payload });
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
      const id = url.pathname.split("/")[3];
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
    const id = url.pathname.split("/").pop();
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
});
