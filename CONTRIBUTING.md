# Contributing to llm-usage-bar

Thanks for your interest in contributing!

## How to contribute

### 1. Open an issue first

Before writing code, please
[open an issue](https://github.com/jonasporto/llm-usage-bar/issues/new)
describing:

- **Bug reports:** what happened, what you expected, your macOS and Swift
  versions, and how to reproduce it
- **Feature requests:** what you would like and why it is useful
- **Questions:** if you are unsure about something

Never paste an OAuth token, Codex credential file, Grok `auth.json`, Keychain
dump, or raw usage response into an issue: redact the values first.

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
git clone https://github.com/YOUR_USERNAME/llm-usage-bar.git
cd llm-usage-bar
swift build
swift test
```

Running the built app is described in the [README](README.md#install).

## Conventions

- **Two targets.** `Sources/UsageCore` holds parsing, formatting and
  decisions, and is tested. `Sources/LLMUsageBar` is the SwiftUI shell.
  New logic goes into `UsageCore` **with a test**.
- **Tests use [Swift Testing](https://github.com/swiftlang/swift-testing)**
  (`@Test` / `#expect`), not XCTest, so the suite runs with Command Line
  Tools alone.
- **Never print, log or persist a token.** Anthropic tokens leave the process
  only in the `Authorization` header to `api.anthropic.com`; xAI tokens leave
  the process only in the `Authorization` header to `cli-chat-proxy.grok.com`;
  Codex authentication remains delegated to `codex app-server`.
- **Nothing machine-specific in the repo.** Keychain service names, config
  dir paths, `CODEX_HOME`, `codexPath`, `GROK_HOME` and account names are user configuration
  (`~/.config/llm-usage-bar/profiles.json`), never constants in the code,
  tests, docs or examples.
- **The usage endpoint rate-limits aggressively and is undocumented.** Read
  the "Polling" section of the README before changing any interval, throttle
  or backoff.
- **Providers share one model.** Normalize provider payloads in `UsageCore`;
  do not branch the SwiftUI layout by provider.
- **English only** in code, comments, UI strings, docs and commit messages.
  Anything shown to the user is formatted with the reader's locale.
- Update `CHANGELOG.md` under `## [Unreleased]` in the same PR when the
  behavior changes.
