# Design notes — ClaudeUsageBar

Why the app is built the way it is, plus the backlog. README covers *what it does and how to
use it*; the code covers *how it's implemented*; this file keeps the *why* and the decisions
that aren't obvious from either. The per-file breakdown lives in the README "Source layout"
table.

## Why a menu-bar app

Chosen over an Übersicht desktop tile or a native WidgetKit tile because it's always one
glance/click away over any app, always-live (no Apple widget refresh throttling), and can read
the Keychain token directly. A single non-sandboxed SwiftUI app (`LSUIElement`, no Dock icon)
polls and renders a `MenuBarExtra` entirely in-process — no companion helper, which the
WidgetKit route would have required. App Sandbox is **off** because a menu-bar utility needs
unrestricted Keychain + network access. Targets macOS 14+ (`MenuBarExtra`, `SMAppService`).

## Max-plan data source

Polls the same undocumented, read-only endpoint Claude Code's own limit indicator uses:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
```

It **does not consume the usage limit** but *is* rate-limited, so we poll ~60 s with backoff
(429 → 90 s doubling, capped 600 s; other errors → 20 s doubling, capped 300 s).

**Source of truth is the `limits` array**, not the legacy top-level `five_hour` / `seven_day`
windows. The live endpoint no longer exposes per-model weekly buckets as `seven_day_<model>`
keys (obfuscated codenames, all `null`); the `limits` array carries each cap's `kind`
(`session` / `weekly_all` / `weekly_scoped`), `percent`, `severity`, reset time, and — for
scoped caps — the model `display_name` (e.g. "Fable"). We render that array generically and
fall back to the legacy windows only if `limits` is absent, so new models appear without code
changes.

## API-plan data source (Admin API)

The second popover section shows a pay-as-you-go **API organization's** month-to-date tokens
and cost — a different data source and auth model from the Max endpoint above.

- **Endpoints (read-only):** `GET /v1/organizations/usage_report/messages` (token counts) and
  `GET /v1/organizations/cost_report` (USD as cents), `bucket_width=1d`, grouped by
  `model` / `description`, paginated via `next_page`. Polled every 5 min (Admin data lags
  ~5 min; cost is daily-granularity), with the same last-good + backoff resilience as the Max
  store.
- **Auth requires an Admin key** (`sk-ant-admin01-…`) in `x-api-key`. Confirmed empirically that
  nothing else is accepted: the Max OAuth token → `403 "Authentication method not allowed for
  this endpoint"`; a standard `sk-ant-api03` workspace key → `401 invalid x-api-key` (while the
  same key returns `200` on `/v1/models`).
- **Hard requirement — a multi-user Console org.** Admin keys exist only for organizations, not
  individual/personal API accounts (no *Settings → Admin keys* page otherwise). An Admin key
  only ever sees its own org, so usage in a different org/account is invisible — a new empty org
  reads all zeros. Documented for users in the README under "API plan usage".

## Token & key storage — reading Keychain without a prompt

Both secrets are read through the `security` CLI rather than the in-process
`SecItemCopyMatching`, on purpose. For an **ad-hoc-signed** app ("Sign to Run Locally"), macOS
greys out "Always Allow" in the keychain prompt and only persists a grant for apps with a stable
Developer ID — so the in-process API would prompt on *every* launch with no way to silence it.
The `security` CLI reads without a prompt.

- **Max OAuth token** — read (never written/refreshed) from Claude Code's own login-Keychain
  item `Claude Code-credentials`; `SecItemCopyMatching` and `~/.claude/.credentials.json` are
  kept as fallbacks. We never refresh it ourselves — doing so would rotate Claude Code's refresh
  token and log it out.
- **Admin API key** — the app owns this one; stored in the login Keychain item
  `ClaudeUsageBar-admin-key` (`AdminKeyStore`), entered via a `SecureField` in the popover.

## Backlog / follow-ups

- Menu-bar label: currently the single worst all-models %; could offer dual `5h/7d` segments,
  or optionally append today's API cost.
- Usage-history sparkline.
- Notifications at 80 / 90 / 100 %.
- Click-through from the popover to the claude.ai / console usage pages.

## References

- Max endpoint + response schema: `savaroma/claude-usage-widget`
  (`docs/usage-endpoint.md`, `macos/claude-usage.60s.py`).
- Admin Usage & Cost API: `platform.claude.com/docs/en/api/usage-cost-api` and the
  `usage_report/messages` + `cost_report` reference pages.
- Prior-art native menu-bar apps: `hamed-elfayome/Claude-Usage-Tracker`,
  `emircanok/claude-usage-app`, `agencyenterprise/claude-meter`, `nikola43/claude-usage-widget`.
