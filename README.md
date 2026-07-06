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

## Requirements

- **A Mac on macOS 14 (Sonoma) or later.** Built and tested on macOS 26 / Apple Silicon.
- **Xcode 15 or later** — the *full* Xcode, not just the Command Line Tools, because
  `xcodebuild` needs the macOS SDK. There is no prebuilt or notarized download; you build the
  app yourself.
- **Claude Code installed and signed in on that same Mac.** The app doesn't log into Claude —
  it reads the OAuth token that Claude Code stores in the login keychain item
  `Claude Code-credentials`. If Claude Code has never authenticated on this machine, that item
  won't exist and the app will just show **"Not logged in — run Claude Code once."** So run
  `claude` and sign in there first.

## Installing on another Mac

Build it on the target Mac (a couple of minutes). **Don't copy the built `.app` from another
machine** — it's ad-hoc signed, so a copied bundle arrives quarantined and Gatekeeper blocks
it. Building locally avoids that entirely.

1. **Check the requirements above** — especially that you're signed into Claude Code on this
   Mac.

2. **Clone and build:**
   ```bash
   git clone git@github.com:bhemen/claude-usage-app.git
   cd claude-usage-app
   xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release build
   ```
   Or open `ClaudeUsageBar.xcodeproj` in Xcode and press Run (⌘R).

   > If `xcodebuild` fails with a "required plug-in failed to load" error on a fresh Xcode,
   > run `xcodebuild -runFirstLaunch` once (installs missing components) and retry.

   The build signs ad-hoc ("Sign to Run Locally") — no Apple Developer account needed. App
   Sandbox is **off** (a menu-bar app needs unrestricted keychain + network access).

3. **Install into `/Applications`** (a stable location — DerivedData can be wiped by a clean
   build) and re-sign the moved bundle:
   ```bash
   APP=$(find ~/Library/Developer/Xcode/DerivedData/ClaudeUsageBar-*/Build/Products \
         -name ClaudeUsageBar.app | head -1)
   cp -R "$APP" /Applications/ClaudeUsageBar.app
   codesign --force --deep --sign - /Applications/ClaudeUsageBar.app
   open /Applications/ClaudeUsageBar.app
   ```
   The app has no Dock icon (`LSUIElement`); look for its gauge icon in the menu bar.

4. **(Optional) Launch at login** — tick the box in the popover, or set it headlessly
   (registration targets the running bundle, so run the installed copy's binary directly):
   ```bash
   /Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --register-login-item
   # undo with: ... --unregister-login-item
   ```
   Either way it uses `SMAppService.mainApp`, so the popover checkbox and the actual state
   stay in sync. It also appears under **System Settings → General → Login Items**.

### First run

You should **not** see a keychain prompt — the app reads the token via the `security` CLI,
which doesn't prompt.

Why not use the direct `SecItemCopyMatching` API first? Because for an **ad-hoc-signed** app
(what "Sign to Run Locally" produces), macOS **greys out "Always Allow"** (or rejects your
password) in the keychain prompt — it only persists a keychain grant for apps with a stable
Developer ID. So the direct API would prompt on *every* launch with no way to silence it.
Trying the `security` CLI first sidesteps that entirely. `SecItemCopyMatching` remains as a
fallback, so if you later sign the app with a stable identity it still works.

### After a reboot

Nothing to re-enter. Your macOS login auto-unlocks the login keychain, the login item (if
enabled) relaunches the app, and it reads the token via the `security` CLI with no prompt.

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

## Updating

After pulling changes (or rebuilding locally), reinstall the built app over the old one:

```bash
git pull
xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release build
APP=$(find ~/Library/Developer/Xcode/DerivedData/ClaudeUsageBar-*/Build/Products \
      -name ClaudeUsageBar.app | head -1)
osascript -e 'quit app "ClaudeUsageBar"' 2>/dev/null
cp -R "$APP" /Applications/ClaudeUsageBar.app
codesign --force --deep --sign - /Applications/ClaudeUsageBar.app
open /Applications/ClaudeUsageBar.app
```

The login-item registration persists across updates as long as the bundle stays at
`/Applications/ClaudeUsageBar.app`.

## Troubleshooting

- **"Not logged in — run Claude Code once":** Claude Code isn't authenticated on this Mac.
  Run `claude` and sign in; the app picks up the token on its next poll.
- **"Stale token — sign in to Claude Code":** the stored token expired and Claude Code hasn't
  refreshed it yet. Run Claude Code once to refresh.
- **"Offline":** no network / endpoint unreachable. The app keeps showing the last good
  snapshot and recovers automatically.
- **`xcodebuild` "required plug-in failed to load":** run `xcodebuild -runFirstLaunch`, then
  rebuild.
- **A keychain password prompt appears anyway:** you can dismiss it — the app reads via the
  `security` CLI regardless. (Entering a password can't succeed for an ad-hoc-signed app; see
  "First run".)
