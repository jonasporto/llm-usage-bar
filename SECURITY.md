# Security Policy

## Supported versions

A single active line: fixes land on `main`. Rebuild from the latest commit
before reporting.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Use GitHub's private reporting — *Security* → *Report a vulnerability* on
https://github.com/jonasporto/llm-usage-bar — which opens a confidential
thread with the maintainer.

Include what you can: your macOS and Swift versions, the commit you built,
and the smallest reproduction you have. **Never include a real OAuth token,
a Keychain dump or an unredacted API response.** You should get an
acknowledgement within a week.

## What the app touches

- Reads Anthropic OAuth tokens from the macOS Keychain entries Claude Code
  wrote, by running `/usr/bin/security find-generic-password`. The token is held in
  memory and sent only in the `Authorization` header of
  `GET https://api.anthropic.com/api/oauth/usage`.
- Reads the account email and organization name from the `.claude.json` of
  each configured profile, to label the popover.
- Starts the configured `codex` executable directly (without a shell), passes
  only the `app-server` argument, and selects a Codex login by setting its
  `CODEX_HOME`. Authentication and rate-limit requests stay inside that
  subprocess; this app does not read Codex credential files.
- Reads xAI OAuth tokens from `$GROK_HOME/auth.json` (default `~/.grok/auth.json`),
  the file the Grok CLI writes. The token is held in memory and sent only in
  the `Authorization` header of `GET https://cli-chat-proxy.grok.com/v1/billing`
  and `GET https://cli-chat-proxy.grok.com/v1/user`.
- Stores in `UserDefaults`: the selected profile and, per profile, the
  balance anchor you typed.

Things that follow from that design and are **not** vulnerabilities:

- The app can read the tokens of every profile you list in
  `profiles.json` — it runs as your user, with your Keychain access.
- macOS may prompt for Keychain access on first run. That prompt is the
  intended boundary.
- A profile's config file is plain text owned by your user; the app only
  reads it.
- `codexPath` is an executable trust boundary. Configure only a Codex CLI you
  installed and trust; the app intentionally runs that exact executable.
- `path` / `adapter` on a custom (or overridden) provider are the same kind of
  trust boundary: the app runs that exact file and never logs its stdout.

Things that **are** in scope: a token reaching any destination other than
`api.anthropic.com` or `cli-chat-proxy.grok.com`; a token appearing in logs,
crash reports, `UserDefaults` or any file; the app reading or persisting Codex
credentials; cross-account Codex or Grok authentication caused by ignoring the
configured `CODEX_HOME` or `GROK_HOME`; command injection through a
`profiles.json` value; and a `configPath`, `keychainService`, `codexPath`,
`grokHome`, `path` or `adapter` that changes command arguments or invokes a
shell unexpectedly.
