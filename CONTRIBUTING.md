# Contributing to claude-usage-bar

Thanks for your interest in contributing!

## How to contribute

### 1. Open an issue first

Before writing code, please
[open an issue](https://github.com/jonasporto/claude-usage-bar/issues/new)
describing:

- **Bug reports:** what happened, what you expected, your macOS and Swift
  versions, and how to reproduce it
- **Feature requests:** what you would like and why it is useful
- **Questions:** if you are unsure about something

Never paste an OAuth token, a Keychain dump, or a raw `/api/oauth/usage`
response into an issue: redact the values first.

### 2. Wait for feedback

Maintainers will review the issue and reply. This avoids duplicate work and
aligns on the approach before code is written.

### 3. Open a pull request

Once the issue is agreed:

1. Fork the repository
2. Create a branch
3. Make your change
4. Run `swift test` — it must be green
5. Open a PR referencing the issue (e.g. `Fixes #12`)

PRs without a linked issue may be closed.

## Development setup

```bash
git clone https://github.com/YOUR_USERNAME/claude-usage-bar.git
cd claude-usage-bar
swift build
swift test
```

Running the built app is described in the [README](README.md#install).

## Conventions

- **Two targets.** `Sources/UsageCore` holds parsing, formatting and
  decisions, and is tested. `Sources/ClaudeUsageBar` is the SwiftUI shell.
  New logic goes into `UsageCore` **with a test**.
- **Tests use [Swift Testing](https://github.com/swiftlang/swift-testing)**
  (`@Test` / `#expect`), not XCTest, so the suite runs with Command Line
  Tools alone.
- **Never print, log or persist a token.** It leaves the process only in the
  `Authorization` header to `api.anthropic.com`.
- **Nothing machine-specific in the repo.** Keychain service names, config
  dir paths and account names are user configuration
  (`~/.config/claude-usage-bar/profiles.json`), never constants in the code,
  tests, docs or examples.
- **The usage endpoint rate-limits aggressively and is undocumented.** Read
  the "Polling" section of the README before changing any interval, throttle
  or backoff.
- **English only** in code, comments, UI strings, docs and commit messages.
  Anything shown to the user is formatted with the reader's locale.
- Update `CHANGELOG.md` under `## [Unreleased]` in the same PR when the
  behavior changes.
