# ClaudeUsageBar

A native SwiftUI **menu-bar app** for macOS that shows your Claude plan usage — the same
numbers as claude.ai *Settings → Usage* (current 5-hour session, weekly all-models, and
per-model weekly caps like Fable) — always one glance away, without opening the browser.

The menu-bar item shows the single highest utilization across your active limits; clicking it
opens a popover with a bar per limit and a live reset countdown.

## How it works

It polls the same read-only endpoint Claude Code's own limit indicator uses:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
```

This call **does not consume your usage limit**, but it *is* rate-limited, so the app polls
every 60 s and backs off on errors (429 → 90 s doubling, capped at 600 s; other errors →
20 s doubling, capped at 300 s).

The bearer token is read straight from the login Keychain item `Claude Code-credentials`
that Claude Code already maintains — the app never logs in or refreshes tokens itself
(doing so would rotate Claude Code's refresh token and log it out). It just re-reads the
current token on each poll.

The token is read by shelling out to the `security` command-line tool
(`security find-generic-password -s "Claude Code-credentials" -w`), which reads the item
**without a keychain prompt**. The in-process Security-framework API (`SecItemCopyMatching`)
is kept only as a secondary path — see "First run" for why it isn't used first.

### Data source note

The live endpoint no longer exposes per-model weekly buckets as `seven_day_<model>` keys
(those are now obfuscated codenames, all `null`). The real source of truth is the
**`limits` array**, which carries each cap's `kind` (`session` / `weekly_all` /
`weekly_scoped`), `percent`, `severity`, reset time, and — for scoped caps — the model's
`display_name` (e.g. "Fable"). The app renders that array directly and falls back to the
legacy top-level `five_hour` / `seven_day` windows only if `limits` is absent.

## Building

Requires macOS 14+ and Xcode 15+ (developed on macOS 26.5 / Xcode 26.6).

```bash
open ClaudeUsageBar.xcodeproj   # then press Run (⌘R)
# or from the command line:
xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Debug build
```

The app is signed ad-hoc ("Sign to Run Locally") — no Developer account needed for personal
use. App Sandbox is **off** (a menu-bar app needs unrestricted Keychain + network access).

### First run

You should **not** see a keychain prompt — the app reads the token via the `security` CLI,
which doesn't prompt.

Why not use the direct `SecItemCopyMatching` API first? Because for an **ad-hoc-signed** app
(what "Sign to Run Locally" produces), macOS **greys out "Always Allow"** in the keychain
prompt — it only persists a keychain grant for apps with a stable Developer ID. So the direct
API would prompt on *every* launch with no way to silence it. Trying the `security` CLI first
sidesteps that entirely. `SecItemCopyMatching` remains as a fallback, so if you later sign the
app with a stable identity it still works.

## Features

- **Menu-bar label:** an icon + the single highest utilization across all active windows
  (your tightest constraint at a glance), color-coded (green `<40`, yellow `40–69`,
  orange `70–89`, red `≥90`).
- **Popover:** a progress bar per window — Current session, Weekly · all models, and each
  per-model weekly cap — with percentage and a live reset countdown ("resets in 4h56m" /
  "resets Tue 9:00 PM").
- **Resilience:** keeps showing the last good snapshot with an error note when offline or
  rate-limited; recovers automatically. Never blanks or crashes on a bad/absent token.
- **Launch at login:** toggle in the popover (uses `SMAppService`).
- **Quit** from the popover.

## Source layout

| File | Responsibility |
|------|----------------|
| `ClaudeUsageBar/Models.swift`            | `Codable` wire model (all fields optional) + view-model rows + ISO-8601 parsing |
| `ClaudeUsageBar/KeychainReader.swift`    | Reads the token: `security` CLI → Security framework → credentials file |
| `ClaudeUsageBar/UsageService.swift`      | Authenticated GET, snake_case decode, 401 re-read-and-retry, typed errors |
| `ClaudeUsageBar/UsageStore.swift`        | `@Observable` poll loop + backoff, holds last-good snapshot |
| `ClaudeUsageBar/LoginItemControl.swift`  | `SMAppService` login-item register/unregister + headless launch flags |
| `ClaudeUsageBar/UsageBar.swift`          | Progress-bar row view, threshold colors, reset-countdown formatting |
| `ClaudeUsageBar/ClaudeUsageBarApp.swift` | `@main` app, `MenuBarExtra` label + popover |

## Making it permanent

Install into `/Applications` (a stable location — DerivedData can be wiped by a clean build)
and enable the login item:

```bash
SRC="$HOME/Library/Developer/Xcode/DerivedData/ClaudeUsageBar-*/Build/Products/Debug/ClaudeUsageBar.app"
cp -R $SRC /Applications/ClaudeUsageBar.app
codesign --force --deep --sign - /Applications/ClaudeUsageBar.app   # re-sign the moved bundle
open /Applications/ClaudeUsageBar.app
```

**Launch at login** can be toggled from the popover, or set headlessly (registration targets
the running bundle, so run the installed copy's binary directly):

```bash
/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --register-login-item
/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --unregister-login-item
```

Either way it uses `SMAppService.mainApp`, so the popover checkbox and the actual state stay
in sync. After a reboot the login keychain auto-unlocks with your macOS login, the app reads
the token via the `security` CLI with no prompt, and the login item relaunches it — nothing
to re-enter.
