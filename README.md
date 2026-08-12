# claude-usage-bar

macOS menu bar gauge for Claude plan limits: the 5h window, weekly limits,
per-model buckets (Opus/Sonnet/Fable) and extra-usage spend, for one or more
Claude Code profiles.

- **Bar icon:** 270° arc gauge of the 5h window (green < 60%, orange < 85%,
  red ≥ 85%) plus the percentage. When the window is maxed and extra usage is
  spending, the text becomes `⚡` and the money spent.
- **Popover:** profile tabs, bars with reset times, extra-usage spend and an
  approximate available balance, rate-limit countdown with auto-retry.
- **Per-model bars** are read from the payload, so a new model shows up with
  no code change.

## Install

Requires macOS 14+ and a Swift toolchain (Xcode or Command Line Tools).

```bash
git clone https://github.com/jonasporto/claude-usage-bar.git
cd claude-usage-bar
swift build -c release
mkdir -p "Claude Usage.app/Contents/MacOS"
cp .build/release/ClaudeUsageBar "Claude Usage.app/Contents/MacOS/"
codesign --force -s - "Claude Usage.app"
open "Claude Usage.app"
```

The bundle `Info.plist` (with `LSUIElement`, so there is no Dock icon) is
versioned at `Claude Usage.app/Contents/Info.plist`. Add the app to *System
Settings → General → Login Items* to have it start with your session.

Quit with ⌘Q while the popover is open.

## Profiles

With no configuration the app reads the default Claude Code profile: Keychain
service `Claude Code-credentials` and `~/.claude.json`.

If you run more than one profile (a separate `CLAUDE_CONFIG_DIR` per account),
list them in `~/.config/claude-usage-bar/profiles.json` — see
[`profiles.example.json`](profiles.example.json):

```json
[
  { "id": "personal", "name": "Personal" },
  { "id": "work", "name": "Work",
    "keychainService": "Claude Code-credentials-abc12345",
    "configPath": "~/.claude-work/.claude.json" }
]
```

| Field | Default | Meaning |
| --- | --- | --- |
| `id` | required | Stable key, used for the stored balance anchor |
| `name` | the id, capitalized | Tab label |
| `keychainService` | `Claude Code-credentials` | Keychain entry Claude Code wrote |
| `configPath` | `~/.claude.json` | Config file that names the account |

Claude Code derives the Keychain suffix of a non-default profile from its
config dir path, so it differs per machine. Find yours with:

```bash
security dump-keychain | grep "Claude Code-credentials"
```

## Privacy

- OAuth tokens are read from the same macOS Keychain entries Claude Code
  writes, via `/usr/bin/security`. They are never displayed, logged or
  written anywhere by this app.
- The only network call is
  `GET https://api.anthropic.com/api/oauth/usage`, with the token in the
  `Authorization` header.
- The balance you type is stored in `UserDefaults` as an anchor
  (`balance:spend-at-that-moment`), never sent anywhere.

## Polling

The usage endpoint rate-limits on a rolling window and its `Retry-After` is
always 0, so the app is deliberately conservative: only the visible profile is
fetched, once every 2 minutes, with a 45s throttle per profile and an
exponential backoff (60s → 600s) on HTTP 429. Steady state is about 30 calls
per hour.

## Test

```bash
swift test   # Swift Testing — no XCTest, so Command Line Tools is enough
```

Parsing, money conversion, profile config and the balance anchor live in
`Sources/UsageCore` and are covered by tests; `Sources/ClaudeUsageBar` is the
SwiftUI shell.

## Contributing

Issues and pull requests are welcome — please read
[CONTRIBUTING.md](CONTRIBUTING.md) first. Security reports: see
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)

This is an unofficial community project. It is not affiliated with,
endorsed by, or supported by Anthropic.
