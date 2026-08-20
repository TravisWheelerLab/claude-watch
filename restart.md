# claude-watch — restart / handoff notes

Everything you need to pick this project back up. Current release: **v0.10**.

## What it is
A tiny macOS menu-bar widget (single Swift file, Cocoa) that shows your Claude
Pro/Max subscription usage — the same numbers as claude.ai/settings/usage —
without opening a browser. Menu bar shows two vertical flood bars (session 5h,
weekly 7d) + a countdown to the next 5h reset; clicking opens a popup with exact
figures. Repo: `TravisWheelerLab/claude-watch` (private), branch `main`.

## Layout
- `ClaudeWatch.swift` — the whole app (~717 lines). Everything lives here.
- `install.sh` — builds `ClaudeWatch.app`, copies to `~/Applications`, writes +
  loads a LaunchAgent (`com.traviswheeler.claudewatch`, RunAtLoad + KeepAlive).
  Records the source-checkout path in `Info.plist` as `CWSourcePath` (needed for
  self-update).
- `build.sh` — builds the `.app` bundle only. `update.sh` — `git pull --ff-only` + install.
- `figures/` — README screenshots (`menu_tool.png`, `claudewatch-popup.png`).
- `Info.plist`, `LICENSE` (BSD-3), `README.md`.

## Build / run / install
```sh
# quick compile-check (always do this after edits)
swiftc ClaudeWatch.swift -o /tmp/cw-build -framework Cocoa && rm -f /tmp/cw-build
# run directly (foreground, no autostart)
swiftc ClaudeWatch.swift -o claude-watch -framework Cocoa && ./claude-watch
# full install (autostart at login + self-update): rebuilds and relaunches
./install.sh
```

## How it gets data
- Endpoint: `GET https://api.anthropic.com/api/oauth/usage` with
  `Authorization: Bearer <oauth token>` + `anthropic-beta: oauth-2025-04-20`.
  Undocumented; not affiliated with Anthropic.
- **Credentials live in one of two places** depending on Claude Code
  version/platform: the login keychain (service `Claude Code-credentials`) OR
  `~/.claude/.credentials.json`. `readCredentials()` reads BOTH and prefers the
  one whose `expiresAt` (Unix millis) is later. This machine uses the keychain;
  no file. See memory `claude-watch-token-handling`.
- The app only *reads* the token; it never refreshes it. `claude auth login`
  (real CLI subcommand) writes a fresh one. The "🔑 Log in to Claude…" button
  opens Terminal running that, then watches the local store every 3s and
  refetches once the token changes.

## The big gotcha: rate limiting
The usage endpoint has a **small (~5-request) token bucket shared across
everything using the same OAuth token** — the widget, Claude Code, and any curl
you run to test. Drain it and you get HTTP 429 for a while. This caused a
day-long "stuck on stale %" bug (v0.6 fix). **When diagnosing, don't hammer the
endpoint with curl** — a few probes drain the bucket and you'll mislead yourself.

## Key functions (ClaudeWatch.swift)
- `readCredentials()` ~106, `credentialsFromFile/Keychain()` ~79/97, `parseCredentials()` ~70
- `fetchUsage(token:)` ~112 — maps HTTP to `FetchResult` (.ok/.authError/.transient/.error)
- `refresh(force:)` ~407 — offline guard, backoff gate, debounce; `force:true` bypasses gates (user actions)
- `apply(_:)` ~430 — state machine incl. 429 backoff + auth self-heal retry
- `renderUsage(_:staleNote:forceNote:)` ~476, `showOffline()` ~534, `setBars` ~550, `rebuildMenu` ~588
- `checkForUpdate()`/`launchUpdate()` ~298/315 — self-update via git on `CWSourcePath`
- `applicationDidFinishLaunching` ~344 — timers, NWPathMonitor, wake observer

## Behavior tuning (constants at top)
`REFRESH_INTERVAL=900` (15m background poll), `BACKOFF_MIN/MAX=15m/60m` (429),
`STALE_AFTER=20m` (flag old data), `EXPIRY_WARN_MINUTES=60`, `WARN_THRESHOLD=60`
(bars go red).

## Feature history (why each release exists)
- v0.4 actionable auth failure: red "⚠ login" + "🔑 Log in to Claude…" button (runs `claude auth login`).
- v0.5 proactive "⚠ Login expires in NNm" within 60 min of expiry.
- v0.6 429 backoff + flag stale data ("⚠ API busy — last good HH:MM"); poll 5m→15m.
- v0.7 read `~/.claude/.credentials.json` too (prefer freshest); smart post-login wait.
- v0.8 network-aware (NWPathMonitor: no API calls while offline, "⚠ No network"
  shown immediately, refetch on reconnect); refresh on wake; auth self-heal
  (~45s retries × up to 4); log *why* auth failed (nil creds vs real 401).
- v0.9 refresh when the 5h window rolls over (was stuck showing "now" on stale
  figures — see `chasedReset` / `updateCountdownText`); opt out of App Nap
  (`appNapActivity`) so the 15-min timer isn't frozen on a windowless app;
  persist last-good usage to `~/Library/Caches/com.traviswheeler.claudewatch/last-usage.json`
  (usage only, no token) so a restart during a 429 shows last figures not a bare
  error (`saveCache`/`loadCache`, models now `Codable`); gentler auth self-heal —
  2 spaced retries (30s, 90s) instead of 4, since each burns a shared bucket token
  and can escalate a brief 401 into a 429 lockout.
- v0.10 stop flashing the "⚠ login" plaque on transient 401s. `apply(.authError)`
  now keeps showing last-good bars during the self-heal retries and only surfaces
  the login prompt when the token has actually expired (`tokenExpiry < now`), the
  retries are spent (`authRetries >= 2`), or there's no cached usage to fall back
  on. v0.9's App-Nap opt-out made the plaque more visible (reliable polling lands
  in more token-rotation windows), which is what surfaced this.

## Self-update (answer to "how do users on old versions upgrade")
Built-in. Checks at launch, every 6h, and on menu-open; if the checkout is behind
`origin` it shows a green **⬆ Update available (vX)** item → one click pulls +
rebuilds + relaunches. Requires: installed via `install.sh` from a git checkout
(so `CWSourcePath` exists) + git/SSH access to the private repo. **A new release
only reaches users once you commit + tag + push it.**

## Release process (do this for every shippable change)
1. Bump `APP_VERSION` in ClaudeWatch.swift.
2. `swiftc ... ` compile-check.
3. Test-drive: the user likes to try builds before commit. For states that are
   hard to reach (auth error, near-expiry, offline), build a throwaway copy that
   forces the state (env-var toggle) into `/tmp`, launch it alongside the
   installed app, let them click through, then clean it up. Never leave real
   tokens in temp files.
4. `./install.sh` to deploy locally; verify via `/tmp/claude-watch-fetch.log`
   (only errors are logged — no new line after a launch = the fetch succeeded).
5. Update `README.md` if behavior changed.
6. Commit, `git tag vX.Y`, push both branch and tag.

## Conventions
- **Network is spotty** — always push with retries:
  `for i in 1 2 3 4 5 6; do git push && git push origin vX.Y && break; sleep 15; done`
  (run un-sandboxed; the sandbox has no network).
- **Commit acknowledgment** (user's global rule): end messages with a plain line
  `Implemented with help from Claude Opus <version>` — NOT the `Co-Authored-By:
  Claude` trailer. (Trivial/mechanical commits: no acknowledgment.)
- Branch off `main` before committing if asked to push; commit/push only when asked.
- `/tmp/claude-watch-fetch.log` is the app's own transient-error log (bounded ~64KB).

## Working style (per user preference — memory `prefer-subagents`)
Spin off sub-agents when it keeps the core context lean or a cheaper model
suffices: fan-out searches → `Explore`; noisy diagnostic probing → a
sub-agent that reports just the finding; routine specified edits → a
smaller-model agent. Keep design decisions and turn-by-turn code review in the
core agent. Still confirm before irreversible/outward-facing actions.

## Current state
Clean working tree, `main` == origin, tags through v0.8 pushed. Installed +
running locally as the LaunchAgent. Nothing pending.
