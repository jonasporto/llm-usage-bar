# Changelog

All notable changes to llm-usage-bar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
