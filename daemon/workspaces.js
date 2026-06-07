const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

function createWorkspaceManager({ root, workspaceStore, hasGithubAuth = () => false }) {
  const workspaces = getConfiguredWorkspaces({ root, workspaceStore });

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

    if (!hasGithubAuth()) {
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

  function saveWorkspaces() {
    fs.writeFileSync(
      workspaceStore,
      JSON.stringify({ workspaces: workspaces.map((workspace) => workspace.path) }, null, 2)
    );
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

  return {
    workspaces,
    addWorkspace,
    listWorkspaceBindings,
    listWorkspaceReadiness,
    repoHeadSha,
    resolveWorkspace,
    workspaceReadiness,
    workspaceRepoBinding
  };
}

function getConfiguredWorkspaces({ root, workspaceStore }) {
  const configured = (process.env.LOUPE_WORKSPACES || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  const saved = readSavedWorkspacePaths(workspaceStore);
  const candidates = configured.length ? configured : [root, ...saved];
  const unique = [...new Set(candidates.map((item) => path.resolve(item)))];

  return unique.map((workspacePath, index) => workspaceFromPath(workspacePath, index));
}

function readSavedWorkspacePaths(workspaceStore) {
  try {
    const parsed = JSON.parse(fs.readFileSync(workspaceStore, "utf8"));
    return Array.isArray(parsed.workspaces) ? parsed.workspaces : [];
  } catch {
    return [];
  }
}

function workspaceFromPath(workspacePath, index) {
  const resolved = path.resolve(workspacePath);
  return {
    id: `workspace-${index}`,
    name: path.basename(resolved) || resolved,
    path: resolved
  };
}

function parseGithubRemote(remote) {
  if (!remote) return null;
  const ssh = remote.match(/^git@github\.com:([^/]+)\/(.+?)(?:\.git)?$/i);
  if (ssh) return { host: "github.com", owner: ssh[1], repo: ssh[2] };
  const https = remote.match(/^https?:\/\/(?:[^@]+@)?github\.com\/([^/]+)\/(.+?)(?:\.git)?\/?$/i);
  if (https) return { host: "github.com", owner: https[1], repo: https[2] };
  return null;
}

module.exports = {
  createWorkspaceManager,
  parseGithubRemote
};
