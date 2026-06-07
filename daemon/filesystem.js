const fs = require("fs");
const os = require("os");
const path = require("path");

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

module.exports = {
  cleanFolderName,
  getFsRoots,
  getUsageSnapshot,
  listFolders
};
