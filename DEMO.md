# Loupe iPhone Demo

This workspace contains a self-contained PWA prototype for controlling Mac-local Codex from an iPhone.

## What the demo shows

- A single-screen Opencode-style workspace/chat interface.
- Dispatching custom chat prompts to Mac-local Codex.
- A tappable session container at the top of the screen.
- A session window with `messages`, `files`, and `actions` tabs.
- Streaming `codex exec --json` events back to the phone.
- Creating new Mac folders/workspaces from the phone and using them as Codex workspaces.

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

## Suggested demo script

1. Open the app on iPhone.
2. Confirm the top-right status says `online`.
3. Pick a workspace in `Let's get building in ...`.
4. Enter a custom message in the thick bottom chatbox.
5. Tap send.
6. Tap the session container at the top of the screen.
7. Review `messages`, `files`, and `actions`.
8. Optional: expand `workspace tools` to create a new Mac folder/workspace.

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
