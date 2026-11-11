# ClaudeUsageBar

A native SwiftUI **menu-bar app** for macOS that shows your Claude plan usage — the same
numbers as claude.ai *Settings → Usage* (current 5-hour session, weekly all-models, and
per-model weekly caps like Fable) — always one glance away, without opening the browser.

The menu-bar item shows your weekly all-models usage (falling back to the tightest active
limit if no all-models cap is reported); clicking it opens a popover with a bar per limit and
a live reset countdown.

**Your Max/Pro plan needs no key or sign-in here.** The app reads the OAuth token Claude Code
already stored on this Mac, so the plan usage appears automatically once you're signed into
Claude Code — there's nothing to paste. (The **Add Admin API key…** button in the popover is
*only* for the separate, optional [API plan usage](#api-plan-usage) section below.)

If you also have a pay-as-you-go **API plan**, the popover can show that organization's
month-to-date **token usage and cost** in a second section — but only for a **multi-user
Console organization**, which is the only kind of account that can create the required Admin
API key. See [API plan usage](#api-plan-usage) for the requirement and setup.

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
- **Xcode 15 or later** — the *full* Xcode, not just the Command Line Tools. The Command Line
  Tools ship compilers and macOS SDKs but no `xcodebuild`, and none of the Xcode build system
  it drives (scheme resolution, asset-catalog compilation, `Info.plist` processing,
  code-signing orchestration) — all of which this `.xcodeproj` needs. There is no prebuilt or
  notarized download; you build the app yourself.
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

2. **Point the toolchain at the full Xcode, and clear its license gate.** If you've only ever
   used the Command Line Tools, `xcode-select` still points at them and `xcodebuild` will fail
   with *"tool 'xcodebuild' requires Xcode"* — the stub at `/usr/bin/xcodebuild` forwards to
   the active developer directory, and there's no `xcodebuild` in the CLT one. A freshly
   installed Xcode also refuses to run until its license is accepted once. Both need `sudo`:
   ```bash
   xcode-select -p    # if this prints /Library/Developer/CommandLineTools, run the next line
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```

3. **Clone and build:**
   ```bash
   git clone https://github.com/bhemen/claude-usage-app.git
   cd claude-usage-app
   xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release build
   ```
   Or open `ClaudeUsageBar.xcodeproj` in Xcode and press Run (⌘R).

   > If `xcodebuild` fails with a "required plug-in failed to load" error (e.g. a missing
   > `DVTDownloads.framework`) on a fresh Xcode, run `xcodebuild -runFirstLaunch` once to
   > install the missing components, then retry. This one does **not** need `sudo`.

   The build signs ad-hoc ("Sign to Run Locally") — no Apple Developer account needed. App
   Sandbox is **off** (a menu-bar app needs unrestricted keychain + network access).

4. **Install into `/Applications`** (a stable location — DerivedData can be wiped by a clean
   build) and re-sign the moved bundle:
   ```bash
   APP=$(find ~/Library/Developer/Xcode/DerivedData/ClaudeUsageBar-*/Build/Products \
         -name ClaudeUsageBar.app | head -1)
   cp -R "$APP" /Applications/ClaudeUsageBar.app
   codesign --force --deep --sign - /Applications/ClaudeUsageBar.app
   open /Applications/ClaudeUsageBar.app
   ```
   The app has no Dock icon (`LSUIElement`); look for its gauge icon in the menu bar.

5. **(Optional) Launch at login** — tick the box in the popover, or set it headlessly
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

- **Menu-bar label:** an icon + your weekly all-models usage (falling back to the tightest
  active limit if no all-models cap is reported), color-coded (green `<40`, yellow `40–69`,
  orange `70–89`, red `≥90`).
- **Popover:** a progress bar per window — Current session, Weekly · all models, and each
  per-model weekly cap — with percentage and a live reset countdown ("resets in 4h56m" /
  "resets Tue 9:00 PM").
- **Resilience:** keeps showing the last good snapshot with an error note when offline or
  rate-limited; recovers automatically. Never blanks or crashes on a bad/absent token.
- **API plan usage (optional):** a second popover section showing an API organization's
  month-to-date cost, tokens, and per-model breakdown via an Admin API key. Requires a
  multi-user org — see [API plan usage](#api-plan-usage).
- **Launch at login:** toggle in the popover (uses `SMAppService`).
- **Quit** from the popover.

## API plan usage

The popover has an optional **API usage** section that shows your Anthropic **API
organization's** month-to-date cost and token usage, separate from the Max-plan limits above.
It reads two **read-only** Admin API endpoints on each poll:

```
GET https://api.anthropic.com/v1/organizations/usage_report/messages   # tokens
GET https://api.anthropic.com/v1/organizations/cost_report             # USD (cents)
```

### Requirement: a multi-user-org Admin key

**This section only works with an Admin API key (`sk-ant-admin01-…`), and Admin keys are only
issued to multi-user Console organizations — not to individual/personal API accounts.** No
other credential is accepted. This isn't a guess; it's verified:

- The OAuth token the Max plan uses → `403` `"Authentication method not allowed for this endpoint"`.
- A standard workspace key (`sk-ant-api03-…`) → `401 invalid x-api-key` — *even though the
  same key returns `200` on `/v1/models`*. The Usage & Cost API accepts nothing but an Admin key.

If your Console account is an individual account, the **Settings → Admin keys** page doesn't
exist and you can't create one — the workspace "Create key" dialog only makes standard
`sk-ant-api03` keys. To get an Admin key you must set up a real **organization** (Console →
Organization settings → add a member so it's genuinely multi-user), then create the key at
**[Settings → Admin keys](https://platform.claude.com/settings/admin-keys)** (requires the
**admin** role — as the org's only member you have it).

> **An Admin key only sees the organization it belongs to.** If you create a *new* org just to
> get the key, that org starts empty and the section shows all zeros — your existing usage
> lives in whichever org owns the API keys that made the calls. Point the Admin key at the org
> whose usage you actually want to monitor, and route your API traffic through that org's keys.

### Adding the key

1. Click the menu-bar icon → in the **API usage** section, click **Add Admin API key…**
2. Paste your `sk-ant-admin01-…` key and click **Save**.

The key is stored in your **login Keychain** (generic-password item `ClaudeUsageBar-admin-key`)
via the `security` CLI — the same prompt-free mechanism used for the Max-plan token. It never
leaves your Mac except as the `x-api-key` header to `api.anthropic.com`. Use **⋯ → Remove Admin
key** to delete it, or **Replace Admin key…** to swap it. The app reads the key once at launch
and keeps it in memory, so edits made directly in Keychain Access take effect after a relaunch;
if a key leaks, revoke it in the Console rather than just deleting it locally. (Saving passes the key as a `security`
argument, so it's briefly visible to `ps` for processes running as you — fine for a personal
Mac; note it if you're on a shared machine.)

### What it shows, and caveats

- **This month / Today** — month-to-date and current-day cost in USD.
- **Tokens** — month-to-date input and output tokens (all input kinds — uncached, cache read,
  and cache creation — summed, matching the console's "tokens in").
- **Per model** — the top models by cost, each with combined token count and cost.
- Polls every **5 minutes**: Admin data lags ~5 min and cost is daily-granularity, so there's
  nothing to gain from polling faster (and the API asks for ≤ 1 request/minute).
- **"Today" is a UTC day** — the cost API buckets on UTC day boundaries, so it rolls over at
  midnight UTC, not local midnight.
- **Priority Tier cost is not included** in the cost endpoint (Anthropic bills it separately);
  its tokens still appear in the token totals.
- Figures are the **API usage/cost reports** — API traffic only, not the Console-Workbench-plus-API
  mix shown on the website's Usage page.

## Source layout

| File | Responsibility |
|------|----------------|
| `ClaudeUsageBar/Models.swift`            | `Codable` wire model (all fields optional) + view-model rows + ISO-8601 parsing |
| `ClaudeUsageBar/KeychainReader.swift`    | Reads the token: `security` CLI → Security framework → credentials file |
| `ClaudeUsageBar/UsageService.swift`      | Authenticated GET, snake_case decode, 401 re-read-and-retry, typed errors |
| `ClaudeUsageBar/UsageStore.swift`        | `@Observable` poll loop + backoff, holds last-good snapshot |
| `ClaudeUsageBar/LoginItemControl.swift`  | `SMAppService` login-item register/unregister + headless launch flags |
| `ClaudeUsageBar/UsageBar.swift`          | Progress-bar row view, threshold colors, reset-countdown formatting |
| `ClaudeUsageBar/ClaudeUsageBarApp.swift` | `@main` app, `MenuBarExtra` label + popover (both sections) |
| `ClaudeUsageBar/AdminKeyStore.swift`     | Admin API key read/write/delete in the login Keychain via the `security` CLI |
| `ClaudeUsageBar/APIUsageModels.swift`    | `Codable` wire models for the usage & cost reports + rollup view model + token formatting |
| `ClaudeUsageBar/APIUsageService.swift`   | Admin API GET (paginated), month-to-date range, tokens+cost rollup, typed errors |
| `ClaudeUsageBar/APIUsageStore.swift`     | `@Observable` API poll loop (5 min) + backoff; owns the Admin key lifecycle |
| `ClaudeUsageBar/APIUsageSection.swift`   | The "API usage" popover section: metrics, per-model rows, key-entry UI |

## Updating

After pulling changes (or rebuilding locally), reinstall the built app over the old one:

```bash
git pull
xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release build
APP=$(find ~/Library/Developer/Xcode/DerivedData/ClaudeUsageBar-*/Build/Products \
      -name ClaudeUsageBar.app | head -1)
if [ -d "$APP" ]; then
  osascript -e 'quit app "ClaudeUsageBar"' 2>/dev/null
  rm -rf /Applications/ClaudeUsageBar.app          # replace the bundle, don't merge into it
  cp -R "$APP" /Applications/ClaudeUsageBar.app
  codesign --force --deep --sign - /Applications/ClaudeUsageBar.app
  open /Applications/ClaudeUsageBar.app
else
  echo "No built .app found under DerivedData — did the build above succeed?"
fi
```

The `rm -rf` matters: `cp -R` onto an *existing* bundle merges into it rather than replacing
it, so a file that a later version drops would survive as a stale leftover and get sealed
into the freshly re-signed bundle. Removing first guarantees the installed app is exactly
what was built. The `[ -d "$APP" ]` guard is what makes that safe — without it, a failed
build leaves `$APP` empty and the `rm -rf` would delete your installed copy with nothing to
put back.

The login-item registration persists across updates as long as the bundle stays at
`/Applications/ClaudeUsageBar.app`.

## Troubleshooting

- **"Not logged in — run Claude Code once":** Claude Code isn't authenticated on this Mac.
  Run `claude` and sign in; the app picks up the token on its next poll.
- **"Stale token — sign in to Claude Code":** the stored token expired and Claude Code hasn't
  refreshed it yet. Run Claude Code once to refresh.
- **"Offline":** no network / endpoint unreachable. The app keeps showing the last good
  snapshot and recovers automatically.
- **`xcodebuild` "requires Xcode, but active developer directory is a command line tools
  instance":** `xcode-select` points at the Command Line Tools, which contain no `xcodebuild`.
  Run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- **`xcodebuild` "You have not agreed to the Xcode license agreements":** run
  `sudo xcodebuild -license accept`.
- **`xcodebuild` "required plug-in failed to load":** run `xcodebuild -runFirstLaunch` (no
  `sudo` needed), then rebuild.
- **A keychain password prompt appears anyway:** you can dismiss it — the app reads via the
  `security` CLI regardless. (Entering a password can't succeed for an ad-hoc-signed app; see
  "First run".)
- **API usage section shows all zeros:** the Admin key is valid but belongs to an
  organization with no usage — most often a *new* org created just to obtain the key. The key
  can only report on its own org; see the note under [API plan usage](#api-plan-usage).
- **"Admin key rejected — check the key":** the stored key isn't a valid `sk-ant-admin01-…`
  Admin key (a standard `sk-ant-api03` workspace key won't work). Use **⋯ → Replace Admin key…**.

## License

[MIT](LICENSE). This is an unofficial personal project — not affiliated with or endorsed by
Anthropic, and it relies on an undocumented endpoint that may change without notice.
