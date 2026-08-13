# Changelog

All notable changes to claude-usage-bar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
- Profiles are no longer hardcoded: the tab list, Keychain service names and
  config paths come from user configuration.
- Money is formatted with the currency from the API payload and the reader's
  locale, instead of a fixed locale.
- The balance field accepts the number format of the reader's locale.
- UI strings and reset times are in English / the reader's locale.

### Fixed
- The profile picker is hidden when only one profile is configured.
