# CLAUDE.md - llm-usage-bar development guide

Guidance for AI assistants working on this codebase.

## Public repository policy

llm-usage-bar is a public open-source project. Two hard rules:

1. **No private context.** Never reference private or personal projects,
   companies, accounts, tickets, internal tools or machine-specific
   environments in anything that lands in this repo — code, comments, tests,
   docs, examples or commit messages. Profile names, Keychain service
   suffixes and config dir paths are user configuration, never constants.
   Keep every example generic (`work`, `abc12345`, `~/.claude-work`).
2. **No unauthorized publishing.** Never push or publish without the
   maintainer's explicit authorization in the current session.

Public git history is permanent: check the diff for private references
*before* committing, not before pushing.

## Overview

A SwiftUI macOS menu bar app that shows Claude, Codex, Grok and Antigravity
plan usage for one or more accounts. Anthropic data comes from its OAuth usage
endpoint using Claude Code's Keychain token; OpenAI data and authentication
come through the local Codex App Server selected by `CODEX_HOME`; xAI data
comes from the Grok CLI billing endpoint using the token in
`$GROK_HOME/auth.json`; Antigravity data comes from `agy -p /quota`, which
authenticates itself.

```
Sources/UsageCore/        # parsing, formatting, config, gauge drawing — TESTED
Sources/LLMUsageBar/      # SwiftUI shell: store, popover, menu bar item
Tests/UsageCoreTests/     # Swift Testing suites
```

## Conventions

- **New logic goes in `UsageCore`, with a test.** The shell stays thin.
  Run `swift test` before proposing a change; it must be green.
- **Tests use Swift Testing** (`@Test` / `#expect`), never XCTest — the suite
  has to run with Command Line Tools alone.
- **Never print, log or persist a token.** Anthropic tokens leave the process
  only in the `Authorization` header to `api.anthropic.com`. xAI tokens leave
  the process only in the `Authorization` header to `cli-chat-proxy.grok.com`.
  Never read Codex auth files; delegate authentication to `codex app-server`.
- **The usage endpoint rate-limits aggressively and is undocumented.** Read
  the "Polling" section of the README before changing any interval, throttle
  or backoff value. `Retry-After` is always 0 and cannot be trusted.
- **Per-model bars are payload-driven.** Both shapes (`seven_day_<model>` keys
  and `limits[]` entries with `kind: weekly_scoped`) are parsed in
  `dynamicWindows`, so a new model needs no code change. Do not hardcode
  model names beyond the display ordering.
- **Providers share normalized windows.** Provider adapters belong in
  `UsageCore`; do not duplicate or branch the SwiftUI layout by provider.
- **Codex accounts are isolated by `CODEX_HOME`.** Launch the configured
  executable directly, never through a shell, and preserve the initialized
  home check before trusting its responses.
- **Grok accounts are isolated by `GROK_HOME`.** Read only that home's
  `auth.json`; never send the token anywhere except the Grok CLI billing and
  user endpoints.
- **Antigravity quota comes from its CLI, never from an endpoint of ours.**
  `agy -p /quota` prints one tab-separated row per model group, and the CLI
  owns the credentials — never read `oauth_creds.json`, the `gemini` Keychain
  item, or call `cloudcode-pa.googleapis.com`. The CLI has no flag for its
  configuration directory, so an isolated account is a `.gemini` directory
  whose parent becomes `$HOME` for the child process; refuse any other `home`
  rather than reporting the default account's quota.
- **English only** in code, comments, UI strings, docs and commit messages.
  Anything the user sees is formatted with the reader's locale, never a fixed
  one.
- Any behavior change updates `CHANGELOG.md` under `## [Unreleased]`; any
  change to profile configuration also updates the README table and
  `profiles.example.json`.

## Build and run

```bash
swift test
swift build -c release
osascript -e 'quit app "LLM Usage"'
cp .build/release/LLMUsageBar "LLM Usage.app/Contents/MacOS/"
codesign --force -s - "LLM Usage.app"
open "LLM Usage.app"
```

The built binary and its signature are gitignored; the bundle `Info.plist` is
tracked.
