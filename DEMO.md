# Loupe iPhone Demo

This workspace contains a self-contained PWA prototype for controlling Mac-local coding agents (Codex and Claude Code) from an iPhone.

## What the demo shows

- A single-screen Opencode-style workspace/chat interface.
- A harness picker (codex / claude code) in the composer — only enabled when the binary is actually installed.
- Dispatching custom chat prompts to the selected Mac-local agent.
- A tappable session container at the top of the screen.
- A session window with `messages`, `files`, and `actions` tabs.
- Streaming agent events back to the phone:
  - Codex: native `codex exec --json` events.
  - Claude Code: `claude -p --output-format stream-json` events, normalized at the daemon into a common shape (thread_start, tool_use, tool_result, file_change, retry, result).
- Creating new Mac folders/workspaces from the phone and using them as agent workspaces.

## Harness setup

The daemon auto-discovers both agents on startup. Run `node daemon.js` and it will print which harnesses are available, e.g.:

```text
Harnesses detected:
  codex        OK   (codex-cli 0.133.0-alpha.1)
               /Applications/Codex.app/Contents/Resources/codex
  claude-code  OK   (2.1.142 (Claude Code))
               /Users/.../Claude/claude-code/2.1.142/claude.app/Contents/MacOS/claude
Default harness: codex
```

Discovery order for Claude:
1. `$CLAUDE_BIN` env var (override)
2. `claude` on `PATH`
3. Claude Desktop's bundled CLI under `~/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude` (latest version wins)

Each harness must be authenticated independently before it can run a task:
- Codex: run `codex` once and complete sign-in.
- Claude Code: run the binary once with `/login` and finish the claude.ai OAuth flow.

## Run locally

```sh
node daemon.js
```

Then open:

```text
http://localhost:4173/index.html
```

## Demo from iPhone on the same Wi-Fi

The current Mac Wi-Fi address is:

```text
192.168.29.90
```

Open this on the iPhone:

```text
http://192.168.29.90:4173/index.html
```

Both devices need to be on the same network, and macOS may ask whether Node can accept incoming connections.

## Install-like PWA demo on iPhone

For Safari service worker / standalone behavior, serve the app from a secure origin.

Recommended demo path:

```sh
tailscale serve --bg 4173
```

Then open the HTTPS Tailscale URL on the iPhone and use:

```text
Share -> Add to Home Screen
```

Alternative paths:

- Deploy the folder to Vercel/Netlify/Cloudflare Pages.
- Use an HTTPS tunnel such as ngrok.

## End-to-end demo script: ticket → agent → PR

Prereqs (one-time):
- Codex signed in (`codex` once) **or** Claude Code signed in (`claude /login` once).
- A GitHub personal access token with `repo` scope.
- At least one of your workspaces is a git checkout with a `github.com` origin remote.

Flow:
1. Open the app on iPhone (PWA installed via Add to Home Screen).
2. Confirm the top-right `daemon` pill says `online`.
3. Tap **inbox** in the topbar.
4. First time only: paste your GitHub token. The token is stored at
   `~/.loupe/config.json` on the Mac (mode 0600) and never travels to the
   phone after submission.
5. See assigned issues and PRs awaiting your review across every repo
   the token can see. Each card shows which Mac workspace it's bound to
   (green tag) or `no workspace` (red tag).
6. Tap an issue assigned to you in a bound repo. The composer fills with
   a structured dispatch brief and the workspace selector auto-switches.
7. Pick a harness (codex / claude code) in the composer's agent row.
8. Tap send. The daemon:
   - Verifies the workspace is a git repo with a clean tree.
   - Checks out a fresh `loupe/<repo>-<issue>-<id>` branch from your
     current HEAD.
   - Spawns the chosen agent with the workspace as cwd.
   - Streams every tool call, file change, and message back to the phone
     in real time.
   - When the agent finishes successfully **with changes**: stages,
     commits with the ticket title + URL trailer, pushes the branch, and
     emits a `pr_ready` event with the GitHub compare URL.
9. Tap the green **open PR draft on GitHub ↗** card in the messages tab.
   On iPhone this deep-links into the GitHub Mobile app's
   "Open a pull request" sheet, pre-filled from your commit.
10. Review on phone, hit **Create pull request**, then approve + merge
    when you're ready.

Reviews:
- Tickets in the **PRs awaiting your review** section dispatch in plain
  mode (no branch, no push). The brief asks the agent to summarize,
  flag risks, and suggest follow-ups without touching files.

Graceful degradations:
- Workspace not bound to GitHub → runs in plain free-form mode, no
  branch created, no warning surface clutter.
- Workspace has uncommitted changes → branch creation is skipped and a
  `branch:skipped` event explains why; the agent still runs in place.
- Agent finishes with no diff → branch is deleted and a `no_changes`
  event is shown.
- `git push` fails (no remote auth, etc.) → `push_failed` event includes
  the exact retry command.

## Filesystem access notes

The phone does not directly access macOS files. The Mac daemon does the filesystem work as the logged-in macOS user.

- "Complete access" means complete access for the daemon process, not root access by default.
- It can read/list folders that the daemon process can read.
- It can create folders where the daemon process has write permission.
- Use the path field to jump to any absolute path, including `/`, `/Users`, or `/Volumes`.
- For locations protected by macOS privacy controls, grant the terminal app running `node daemon.js` Full Disk Access in System Settings.
- The current build supports browse + create-workspace only. Delete, rename, move, and file editing should stay behind explicit confirmation gates.

## Empty workspace behavior

Phone-created folders are often empty and not git repositories. The daemon starts Codex with:

```text
--skip-git-repo-check
```

That lets Codex run in new folders like `Phonetest-01`. Without it, Codex refuses with `Not inside a trusted directory`.

## Files

- `index.html` - the home screen, workspace selector, chatbox, and session-window UI.
- `daemon.js` - the local Mac daemon that serves the PWA, creates workspaces, and starts `codex exec --json`.
- `.loupe-workspaces.json` - persisted workspace paths.
- `manifest.webmanifest` - app metadata for mobile install.
- `sw.js` - cache-first service worker for secure-origin PWA mode.
- `icons/app-icon.svg` - app icon.
