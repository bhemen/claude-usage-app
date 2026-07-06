# Plan: Claude Usage Menu-Bar App (macOS)

## Context

Brett is on a Claude **Max (20x)** plan and wants an always-glanceable view of the same
numbers the claude.ai *Settings → Usage* popup shows (current 5-hour session, weekly
"All models", weekly per-model like Fable) without opening the browser. We chose a
**native SwiftUI menu-bar app** (over an Übersicht desktop tile or a native WidgetKit
tile) because it's always one glance/click away over any app, is always-live (no
Apple refresh throttling), and can read the token directly.

**Data source (confirmed):** the same undocumented endpoint Claude Code's own limit
indicator uses —
`GET https://api.anthropic.com/api/oauth/usage`
with headers `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`.
It is **read-only and does not consume your usage limit**, but it *is* rate-limited, so
we poll ~every 60s with backoff. The OAuth access token already lives on this machine in
the login Keychain under service `Claude Code-credentials` (verified present); Claude Code
keeps it refreshed, so we just re-read it each poll — no login/refresh flow to build.

**Environment (verified):** macOS 26.5, Xcode 26.6, Swift 6.3 — `MenuBarExtra` and
`SMAppService` (login item) are fully available.

## Response shape

Each section may be `null`; `utilization` is a percent 0–100, `resets_at` is ISO-8601:

```jsonc
{
  "five_hour":        { "utilization": 0.0,  "resets_at": "2026-07-06T13:10:00+00:00" },
  "seven_day":        { "utilization": 60.0, "resets_at": "2026-07-07T16:59:00+00:00" },
  "seven_day_sonnet": { "utilization": 0.0,  "resets_at": "..." },
  "seven_day_opus":   null,
  "extra_usage":      { "is_enabled": false, ... }
}
```

The screenshot's rows map as: **Current session → `five_hour`**, **All models →
`seven_day`**, **Fable → a per-model weekly bucket** (likely `seven_day_fable` or a
generic per-model entry). The documented schema only lists sonnet/opus, so **step 1 is to
curl the live endpoint and see the actual current keys** (Fable is newer than the doc) and
render *all* present weekly buckets generically rather than hardcoding model names.

## Approach

A single non-sandboxed SwiftUI app (`LSUIElement`, no Dock icon) that polls the endpoint
and renders a `MenuBarExtra`. Menu-bar apps aren't sandboxed, so everything is in-process —
no companion helper needed (which is exactly what the WidgetKit route would have required).

**Project:** this repo, `~/sandbox/claude-usage-app/`. Create an Xcode project
`ClaudeUsageBar.xcodeproj` (macOS App target, SwiftUI lifecycle, deployment target macOS 14,
App Sandbox **off**).

### Components (Swift files under the app target)

- **`Models.swift`** — `Codable` structs with **every field optional** so a schema change
  degrades gracefully: `UsageResponse` (`five_hour`, `seven_day`, plus a catch-all for any
  additional `seven_day_*` model buckets), `UsageWindow { utilization: Double?, resets_at: String? }`,
  `ExtraUsage`. Decode extra keys via a custom `init(from:)` that scans the JSON for keys
  prefixed `seven_day` so Fable/future models appear automatically.

- **`KeychainReader.swift`** — reads the token. Primary: Security framework
  `SecItemCopyMatching` for a generic password with service `Claude Code-credentials`
  (falls back to shelling `security find-generic-password -s "Claude Code-credentials" -w`
  if needed), then JSON-decode `claudeAiOauth.accessToken`. Fallback: read
  `~/.claude/.credentials.json` (absent on this machine, but Claude Code may use it after
  updates). First read triggers a one-time macOS "allow keychain access" prompt → *Always Allow*.

- **`UsageService.swift`** — `async` `URLSession` GET with the two headers; decodes
  `UsageResponse`. On **401**, re-read the token once (Claude Code may have just rotated it)
  and retry; do **not** implement OAuth refresh ourselves (rotating the refresh token would
  log Claude Code out). Surface HTTP status to the caller for backoff.

- **`UsageStore.swift`** (`@Observable` / `ObservableObject`) — owns a repeating 60s poll
  `Timer`, holds `lastGood` snapshot + `lastUpdated` + `errorReason`, and a backoff schedule
  (429 → 90s×2^n capped at 600s; other errors → 20s×2^n) so we never hammer the rate-limited
  API. Backoff/color logic mirrors the proven reference SwiftBar script.

- **`UsageBar.swift`** — the progress-bar view matching the screenshot: `Capsule` track +
  colored fill, with threshold colors (`<40` green, `40–69` yellow, `70–89` orange,
  `≥90` red). Plus a helper for the reset countdown ("resets in 4h56m" / "resets Tue 4:59 PM").

- **`ClaudeUsageBarApp.swift`** — `@main` `App` with a `MenuBarExtra`:
  - **Label:** compact + color-coded — the single **highest** utilization across active
    windows (your tightest constraint at a glance), e.g. a filled SF Symbol + `60%`.
  - **Content** (`.menuBarExtraStyle(.window)`): a popover mirroring the screenshot —
    "Plan usage limits · Max (20x)" header, a `UsageBar` row per window (Current session,
    All models weekly, then each per-model weekly bucket incl. Fable), each with % and reset
    text; footer "updated Ns ago", a Refresh button, a "Launch at login" toggle, and Quit.

- **Login item:** `SMAppService.mainApp.register()/unregister()` behind the toggle.

### Distribution

Personal use: build & run from Xcode; sign ad-hoc (or with a Developer ID if you want it
portable/movable to `/Applications`). No notarization needed for local personal use. Document
the first-run Keychain prompt in the README.

## Build order

1. **Confirm live schema & token path** (below) — do this before writing model code.
2. Scaffold the Xcode project (App Sandbox off, `LSUIElement` = YES, deployment macOS 14).
3. `KeychainReader` → `Models` → `UsageService`, verified against the curl output.
4. `UsageStore` (poll + backoff).
5. `UsageBar` + `MenuBarExtra` UI.
6. Login-item toggle, README, ad-hoc sign.

## Verification (end-to-end)

1. **Confirm the live schema & token path first:**
   ```bash
   TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w \
     | python3 -c 'import json,sys;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
   curl -s https://api.anthropic.com/api/oauth/usage \
     -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" | python3 -m json.tool
   ```
   Compare the returned percentages against the Settings → Usage popup and note the exact
   key used for **Fable**; shape the `Models.swift` catch-all accordingly.
2. **Build & run:** `xcodebuild -scheme ClaudeUsageBar build` then launch, or open in Xcode
   and Run. Approve the Keychain prompt.
3. **Correctness:** the menu-bar % and popover bars match the browser popup (session, All
   models, per-model incl. Fable). Reset countdowns tick down.
4. **Resilience:** bad token → app shows "stale token / not logged in", not a crash; kill
   Wi-Fi → shows last-good + "offline", recovers on reconnect; confirm ≤ ~1 request/60s and
   backoff on a simulated 429.
5. **Login item:** toggle on, reboot / re-login, confirm auto-start with no Dock icon.

## Open follow-ups (not blocking)

- Menu-bar label content: single worst % (proposed) vs. dual `5h/7d` segments — tweak once seen live.
- Later niceties: usage-history sparkline, notifications at 80/90/100%, click-through to the
  claude.ai usage page.

## References

- Endpoint + response schema documented in `savaroma/claude-usage-widget`
  (`docs/usage-endpoint.md`) and its `macos/claude-usage.60s.py` (token read, backoff, colors).
- Prior-art native menu-bar apps to crib UI from: `hamed-elfayome/Claude-Usage-Tracker`,
  `emircanok/claude-usage-app`, `agencyenterprise/claude-meter`, `nikola43/claude-usage-widget`.
