const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const HOST = "0.0.0.0";
const PORT = Number(process.env.PORT || 4173);
const ROOT = __dirname;
const CODEX_BIN = process.env.CODEX_BIN || "/Applications/Codex.app/Contents/Resources/codex";
const WORKSPACE_STORE = path.join(ROOT, ".loupe-workspaces.json");
const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const CODEX_SESSIONS_DIR = path.join(CODEX_HOME, "sessions");

const sessions = new Map();
const recentRequests = [];
const workspaces = getConfiguredWorkspaces();

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
  const files = listJsonlFiles(CODEX_SESSIONS_DIR)
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
  const enriched = { at: new Date().toISOString(), ...event };
  session.events.push(enriched);
  for (const res of session.clients) {
    res.write(`data: ${JSON.stringify(enriched)}\n\n`);
  }
}

function createSession(message, workspaceId) {
  const workspace = resolveWorkspace(workspaceId);
  const id = `codex-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const session = {
    id,
    message,
    workspace,
    status: "running",
    events: [],
    clients: new Set(),
    startedAt: new Date().toISOString(),
    exitCode: null
  };
  sessions.set(id, session);

  addEvent(session, {
    type: "status",
    status: "starting",
    text: "Starting Codex on this Mac..."
  });

  const args = [
    "exec",
    "--json",
    "--sandbox",
    "workspace-write",
    "--skip-git-repo-check",
    "-C",
    workspace.path,
    message
  ];

  addEvent(session, {
    type: "command",
    text: `${CODEX_BIN} ${args.map((arg) => (arg.includes(" ") ? JSON.stringify(arg) : arg)).join(" ")}`
  });

  const child = spawn(CODEX_BIN, args, {
    cwd: workspace.path,
    env: { ...process.env, NO_COLOR: "1" },
    stdio: ["ignore", "pipe", "pipe"]
  });

  session.child = child;

  let stdoutBuffer = "";
  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString();
    const lines = stdoutBuffer.split(/\r?\n/);
    stdoutBuffer = lines.pop() || "";
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        addEvent(session, { type: "codex", payload: JSON.parse(line) });
      } catch {
        addEvent(session, { type: "stdout", text: line });
      }
    }
  });

  child.stderr.on("data", (chunk) => {
    addEvent(session, { type: "stderr", text: chunk.toString() });
  });

  child.on("error", (error) => {
    session.status = "failed";
    addEvent(session, { type: "error", text: error.message });
  });

  child.on("close", (code) => {
    if (stdoutBuffer.trim()) {
      addEvent(session, { type: "stdout", text: stdoutBuffer.trim() });
    }
    session.exitCode = code;
    session.status = code === 0 ? "completed" : "failed";
    addEvent(session, {
      type: "done",
      status: session.status,
      exitCode: code,
      text: code === 0 ? "Codex session completed." : `Codex exited with code ${code}.`
    });
  });

  return session;
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
      cwd: ROOT,
      sessions: sessions.size,
      urls: getNetworkUrls(),
      workspaces,
      fsRoots: getFsRoots(),
      codexUsage: getCodexUsage(),
      recentRequests
    });
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

  if (req.method === "POST" && url.pathname === "/api/codex/start") {
    try {
      const body = JSON.parse(await readBody(req) || "{}");
      const message = String(body.message || "").trim();
      if (!message) {
        sendJson(res, 400, { ok: false, error: "Message is required." });
        return;
      }
      const session = createSession(message, body.workspaceId);
      sendJson(res, 200, {
        ok: true,
        sessionId: session.id,
        status: session.status,
        workspace: session.workspace
      });
    } catch (error) {
      sendJson(res, 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "GET" && url.pathname.startsWith("/api/codex/events/")) {
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
    for (const event of session.events) {
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
  console.log("Open from this Mac or iPhone:");
  for (const url of getNetworkUrls()) {
    console.log(`  ${url}`);
  }
});
