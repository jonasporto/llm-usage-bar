# Security Policy

## Supported versions

A single active line: fixes land on `main`. Rebuild from the latest commit
before reporting.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Use GitHub's private reporting — *Security* → *Report a vulnerability* on
https://github.com/jonasporto/claude-usage-bar — which opens a confidential
thread with the maintainer.

Include what you can: your macOS and Swift versions, the commit you built,
and the smallest reproduction you have. **Never include a real OAuth token,
a Keychain dump or an unredacted API response.** You should get an
acknowledgement within a week.

## What the app touches

- Reads OAuth tokens from the macOS Keychain entries Claude Code wrote, by
  running `/usr/bin/security find-generic-password`. The token is held in
  memory and sent only in the `Authorization` header of
  `GET https://api.anthropic.com/api/oauth/usage`.
- Reads the account email and organization name from the `.claude.json` of
  each configured profile, to label the popover.
- Stores in `UserDefaults`: the selected profile and, per profile, the
  balance anchor you typed.

Things that follow from that design and are **not** vulnerabilities:

- The app can read the tokens of every profile you list in
  `profiles.json` — it runs as your user, with your Keychain access.
- macOS may prompt for Keychain access on first run. That prompt is the
  intended boundary.
- A profile's config file is plain text owned by your user; the app only
  reads it.

Things that **are** in scope: a token reaching any destination other than
`api.anthropic.com`; a token appearing in logs, crash reports, `UserDefaults`
or any file; command injection through a `profiles.json` value; and a
`configPath` or `keychainService` that escapes into arbitrary command
execution.
