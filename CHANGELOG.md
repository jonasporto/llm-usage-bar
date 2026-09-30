# Changelog

All notable changes to llm-usage-bar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-09-30

### Added
- The installer registers the app as a login item, so the gauge is back in
  the menu bar after a reboot without anyone remembering to open it. It is the
  same entry *System Settings → General → Login Items* shows, removing it
  there sticks, and re-running the installer never adds a second one.
  `LLM_USAGE_BAR_SKIP_LOGIN_ITEM=1` installs without it.
- Any bar can be pinned as the menu bar gauge for its account: hover it and
  click the pin. Each account keeps its own pin, so switching accounts
  switches the gauge; clicking the pin again, or the provider no longer
  reporting that window, returns the gauge to the primary window.
- Hovering the menu bar gauge shows the account, the window it is showing and
  when it resets.
- Clicking the account line under the picker blurs the email and the plan or
  organization beside it, for screen sharing and screenshots; clicking again
  shows it. The choice is remembered.

### Changed
- An account line with a long plan or organization name stays on one line;
  the name truncates before the email does.

### Fixed
- The popover fits its content again on macOS 26 and later. SwiftUI's
  `MenuBarExtra` window sized itself once and stopped following the content,
  so opening the account picker overflowed the top and switching to an
  account with fewer bars left it floating in a stale, taller frame. The
  status item and popover are now AppKit (`NSStatusItem` + `NSPopover`
  hosting the same SwiftUI view), which resizes with the content. ⌘Q with
  the popover open still quits.

## [1.1.0] - 2026-09-03

### Added
- The installer now bootstraps everything needed to add accounts, providers
  and overrides, with no directory to create by hand: a starter
  `~/.config/llm-usage-bar/profiles.json` (a pre-rename
  `~/.config/claude-usage-bar/profiles.json` is carried over instead, and an
  existing file is never overwritten), `profiles.example.json`, `icons/` with
  the provider marks and `example.svg`, and a runnable `example-usage` in
  `~/.local/share/llm-usage-bar/adapters/`.
- Adapters are discovered by provider name, so `"provider": "ollama"` finds
  `ollama-usage` (or `ollama`) without a `path` in `profiles.json`. Lookup
  order: the adapters directory (`$XDG_DATA_HOME`), `~/.local/bin/llm-usage-bar/`,
  `~/.config/llm-usage-bar/adapters/`, `$PATH`, then `~/.local/bin/`,
  `/opt/homebrew/bin/` and `/usr/local/bin/`.
- Poll cadence is configurable: `refreshSeconds` defaults for every account in
  `~/.config/llm-usage-bar/config.json`, and any account can override it in
  `profiles.json`. Both are clamped to 60–3600 — the usage endpoint
  rate-limits on a rolling window, so a tighter interval returns the same
  numbers and buys a backoff. Saving either file applies the change without
  restarting.
- Antigravity / Gemini CLI accounts (`antigravity`, alias `agy`) can now appear
  alongside Anthropic, OpenAI and xAI accounts, with default isolation in
  `~/.gemini` (or a custom `home`).
- Antigravity quota is read from the Antigravity CLI (`agy -p /quota`), which
  owns the account's credentials — the app sends no Google token of its own.
  Each model group (`Gemini Models`, `Claude and GPT models`) becomes a weekly
  bar with its own reset time, and the group consuming the most drives the menu
  bar gauge. For Antigravity, `path` now names that CLI, the meaning it already
  had for Codex; `adapter` (or a discovered `antigravity-usage` / `agy-usage`)
  still replaces the fetch. An isolated account is a `.gemini` directory with a
  parent of its own, which becomes `$HOME` for the CLI; any other `home` is
  refused with an explanation instead of reporting the default account.
- Dedicated Antigravity SVG mark in the provider picker, with support for
  custom `icon` overrides for any profile.
- Auto-discovery of `antigravity-usage` / `agy-usage` adapter executables from
  `$PATH`, `~/.local/bin/`, or `/opt/homebrew/bin/`, with explicit `path` or
  `adapter` overrides in `profiles.json`.
- Automatic active Google account identity lookup from `google_accounts.json`
  when adapter account output is absent.
- xAI/Grok accounts, including multiple isolated `GROK_HOME` directories, can
  now appear alongside Anthropic and OpenAI accounts. Usage comes from the
  Grok CLI billing endpoint using the token in `$GROK_HOME/auth.json`.
- Saving `profiles.json` reloads the account list without restarting, whether
  the editor replaces the file atomically or truncates and rewrites it in
  place. A half-written file is ignored so the current accounts stay put.
- Unknown providers can be added with `path` or `adapter` pointing at a
  one-shot usage executable that prints the shared snapshot JSON. `adapter`
  also overrides a built-in provider's fetch. `icon` is an optional SVG.
- README: curl-able adapter and icon examples so a custom provider can be
  registered without cloning the repository.

### Changed
- Antigravity adapter discovery uses the shared lookup above, so
  `antigravity-usage` / `agy-usage` are also found in the adapters directory
  without a `$PATH` change.
- README: step-by-step for adding accounts and choosing a provider, with the
  picker marks for Anthropic, OpenAI, xAI and Antigravity.
- Profile isolation uses the shared `home` field (and optional `path`). Each
  provider maps it: Claude Keychain + `.claude.json`, Codex `CODEX_HOME`,
  Grok `GROK_HOME`. Legacy keys still decode.
- The app, bundle identifier, Swift target and config directory are now
  `LLM Usage` / `llm-usage-bar`. An existing
  `~/.config/claude-usage-bar/profiles.json` is still read when the new path
  is absent. Installing replaces `Claude Usage.app` in the same directory.

### Fixed
- An adapter's declared primary window no longer loses to the first window:
  the per-window default made both primary, so the picker showed the wrong
  model's gauge (an Antigravity account showed `Gemini Models` while
  `Claude and GPT models` was the declared primary).
- README: `extraUsage.usedCredits` and `monthlyLimit` are documented as minor
  units, which is how the app has always read them.
- README: the no-affiliation notice now covers Google as well.

## [1.0.0] - 2026-09-02

### Added
- A local or `curl | sh` installer builds from source, ad-hoc signs, installs
  the app in the user's Applications directory, and opens it without `sudo`.
- OpenAI/Codex accounts, including multiple isolated `CODEX_HOME` directories,
  can now appear alongside multiple Anthropic/Claude accounts.
- Provider marks identify Anthropic and OpenAI accounts in the account picker.
- Every account-picker row shows its primary usage gauge and percentage;
  opening the picker fills gauges that have not been loaded yet.
- Codex authentication and rate-limit reads use the local `codex app-server`;
  the app never reads Codex credential files.
- Profiles are configured in `~/.config/claude-usage-bar/profiles.json`
  (`$XDG_CONFIG_HOME` honored), with `profiles.example.json` as a starting
  point. With no config file the app reads the default Claude Code profile.
- `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, this changelog, and
  agent guidance in `CLAUDE.md`.
- GitHub Actions: `swift build` + `swift test` and a signed release-mode
  bundle build on every push and pull request, plus a gate that closes
  external pull requests with no linked issue.
- README: build status badge and screenshots of the menu bar gauge and the
  popover (`docs/`).
- Tests for profile configuration and for reading a typed balance.

### Changed
- Usage windows from both providers now share one payload-driven model and UI.
- The segmented profile tabs are now an expandable account picker that scales
  to more accounts and providers.
- Last-updated timestamps are tracked per account instead of globally.
- Profiles are no longer hardcoded: the tab list, Keychain service names and
  config paths come from user configuration.
- Money is formatted with the currency from the API payload and the reader's
  locale, instead of a fixed locale.
- The balance field accepts the number format of the reader's locale.
- UI strings and reset times are in English / the reader's locale.
- Future-day reset labels include weekday, day, and month instead of only the
  weekday and time.

### Fixed
- The profile picker is hidden when only one profile is configured.
- Expanding the account picker no longer repeats the already-selected account.
- Provider marks stay in a fixed column across the expanded account options;
  each compact gauge/percentage pair reaches the trailing inset. The selected
  header keeps its natural disclosure layout.
