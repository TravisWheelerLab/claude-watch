# claude-watch

A tiny macOS menu-bar widget for keeping an eye on your Claude Pro/Max
subscription usage — the same numbers shown at
[claude.ai/settings/usage](https://claude.ai/settings/usage), without opening a
browser.

## What it shows

In the menu bar: **two vertical red flood bars** (left = current 5-hour
session, right = rolling 7-day weekly) that fill from the bottom as usage
grows, plus a compact countdown (e.g. `2h33m`) to the next 5-hour reset.

Click it for a dropdown with the exact figures:

```
Claude Usage
─────────────────────────────────────────
Session 5h      8%  █░░░░░░░░░  ↻ today 6:10 PM
Weekly 7d      73%  ███████░░░  ↻ Tue 6:00 AM
Extra spend    34%  ███░░░░░░░  $13.50/$40.00
─────────────────────────────────────────
Updated 2:20 PM
Refresh now            ⌘R
Open usage page…
Quit
```

It refreshes every 5 minutes and on each click; the countdown ticks every
minute. The icon adapts to the menu bar; the title turns into a warning if the
usage data can't be fetched.

## How it works

There is no official public API for consumer subscription usage. This app uses
the same **undocumented** endpoint that Claude Code's own `/usage` bar relies
on:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth access token>
```

The OAuth access token is read at runtime from the macOS **login keychain**
(service `Claude Code-credentials`, written there by Claude Code) — it is never
stored in this project. The JSON response contains `five_hour`, `seven_day`,
per-model windows, and an `extra_usage` block (whose dollar fields are in
**cents**).

> ⚠️ This relies on an undocumented endpoint and credential location, both of
> which can change without notice. Not affiliated with or endorsed by Anthropic.

## Requirements

- macOS with the Swift toolchain (`swiftc` — Command Line Tools or Xcode)
- An active Claude Code login on the same machine (Pro/Max subscription)

## Build & run

```sh
swiftc ClaudeMeter.swift -o claude-meter -framework Cocoa
./claude-meter
```

The first run may prompt for keychain access — choose **Always Allow**.

## Start at login (optional)

Wrap the binary in a `.app` bundle and install a LaunchAgent
(`~/Library/LaunchAgents/…plist`) with `RunAtLoad` + `KeepAlive` so it starts
at login and relaunches if it crashes.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
