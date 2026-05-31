# Loupe - Alpha Readiness

Status snapshot: 2026-05-31.

## Alpha Scope

Alpha is the LAN closed loop:

- Pair phone to Mac over LAN.
- Connect GitHub with Device Flow.
- Load assigned GitHub issues.
- Show blueprint trust signals: confidence, cost, degraded, stale.
- Dispatch with the default or alternate harness.
- Show a short cancelable dispatch grace banner, then open the full-screen live session.
- Stream agent events over SSE.
- Create/review a PR in-app and merge or reject it.

Out of scope for alpha: OAuth redirect flow, stable Cloudflare tunnel, named tunnel setup,
repo relocation, and production pairing hardening.

## Current State

- [x] LAN pairing and re-pair recovery.
- [x] GitHub Device Flow screen for missing auth.
- [x] Inbox loading, empty, failed, and offline/retry states.
- [x] Blueprint cost, degraded warning, stale badge, and Refresh action.
- [x] Dispatch button uses blueprint `default_agent`.
- [x] Kebab menu supports alternate harness, Refresh Blueprint, Open in GitHub, Copy Link.
- [x] Dispatch grace banner with Cancel and Now actions.
- [x] Existing full-screen session stream via SSE.
- [x] PR review screen with handoff/body, changed files, merge, and reject.
- [x] Daemon refresh endpoint: `POST /api/v1/blueprints/:owner/:repo/:number/refresh`.
- [x] Daemon returns `staleFiles`.
- [x] Tunnel is opt-in only: `--tunnel` or `LOUPE_TUNNEL=1`.
- [x] Codex execution passes its execution model; cost estimate uses the default harness model.
- [x] Claude execution allowed tools no longer include `WebFetch`.

## Physical Device Verification

Before opening the iOS app, run the daemon smoke check from this repo:

```bash
LOUPE_HOST=http://127.0.0.1:4173 node scripts/alpha-smoke.js
```

On the Mac, the script reads `~/.loupe/config.json` for the pairing token. You can
still override with `LOUPE_TOKEN=<token>` or `--token <token>`. Without a token,
the script confirms the daemon is reachable and prints the pairing-token preview.
With a token, it checks health, workspace readiness, session-start validation,
inbox auth, and the Blueprint refresh auth gate before you move to the phone.

Run the app on device and verify:

1. Fresh paired app with no GitHub token routes to Connect GitHub.
2. Device Flow completes, inbox reloads, and assigned issues appear.
3. Dispatch shows the bottom grace banner; Cancel prevents session launch.
4. Dispatch Now or timeout opens SessionView and streams events.
5. Kebab alternate harness opens SessionView with the selected harness shown.
6. PR ready event opens PR review; Merge and Reject call the daemon successfully.
7. Stale blueprint shows the badge and Refresh regenerates the blueprint.
