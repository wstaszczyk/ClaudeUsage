# ClaudeUsage

A macOS menu-bar app that shows your Claude Code 5-hour plan budget and weekly usage at a glance — without opening Claude Desktop.

![menu bar](https://img.shields.io/badge/macOS-13%2B-blue) ![status](https://img.shields.io/badge/status-experimental-orange) ![license](https://img.shields.io/badge/license-MIT-green)

```
🟢 27% · 3:50
```

---

## ⚠️ Status: experimental

This app uses an **undocumented Anthropic API** and reads internal Claude Desktop data. It may break at any time — for example, when Claude Desktop updates the cookie format, renames the `kelp_forest_sonnet` key, or changes the usage endpoint.

**This project is not affiliated with, endorsed by, or supported by Anthropic.** Use at your own risk.

---

## What it does

- Live 5-hour rolling budget as `% used + exact reset clock time` in the menu bar
- Colour zones: 🟢 0–74% · 🟡 75–89% · 🔴 90–100%
- Dropdown with: progress bar, reset clock, "X minutes remaining"
- Weekly section: "All models" + "Claude Design" percentages (when API is reachable)
- Automatic JSONL fallback when the API session expires — shows approximate usage from `~/.claude/projects/*.jsonl` locally
- Auto-refresh every 30 seconds
- Launch-at-login toggle

---

## Privacy — what it reads

Before you run anything that touches your Keychain, you should know exactly what it does. **The whole privacy-sensitive surface is in a single Swift file** — read it in 5 minutes: [`ClaudeUsage/ClaudeUsage/UsageService.swift`](ClaudeUsage/ClaudeUsage/UsageService.swift).

| What it reads | Where | How |
|---|---|---|
| `Claude Safe Storage` Keychain entry | macOS Keychain | Read-only, with one-time consent prompt |
| Session cookie | `~/Library/Application Support/Claude/Cookies` (SQLite) | Read-only |
| Organisation UUID | `~/.claude.json` | Read-only |
| Conversation transcripts (token counts only) | `~/.claude/projects/**/*.jsonl` | Read-only, fallback path |

**Network:** the app only talks to `api.anthropic.com`. Nothing else.

**Storage / logging:** the session key is held in memory during a single request and never written to disk, never logged, never transmitted anywhere except Anthropic's own API.

**Identity:** the app identifies itself honestly to Anthropic's API with `User-Agent: ClaudeUsage/0.1 (+https://github.com/wstaszczyk/ClaudeUsage)` — no browser spoofing.

---

## How it works

The app replicates what Claude Desktop's "Usage" view computes:

1. **Auth:** decrypts the `sessionKey` cookie from Claude Desktop's local SQLite using AES-128-CBC. The key is derived via PBKDF2-HMAC-SHA1 from the `Claude Safe Storage` Keychain password (this is the standard Chromium cookie-encryption scheme).
2. **API call:** `GET https://api.anthropic.com/api/organizations/{uuid}/usage` with the session cookie. Returns `five_hour.utilization` and `seven_day.*` percentages directly.
3. **Fallback (when API is unreachable):** walks `~/.claude/projects/**/*.jsonl`, sums `cache_creation_input_tokens` over the current 5-hour window (greedy walk backwards; 5h gap = block boundary), divides by `~/.claude.json → clientDataCache.kelp_forest_sonnet` (default 1 000 000). Marked "Estimated" in the UI.

---

## Requirements

- **macOS 13** (Ventura) or later
- **Xcode 15** or later
- **Claude Desktop** installed and signed in (the app reads its local Keychain entry, cookie store, and `~/.claude.json`)

---

## Install

### Quick (one command, requires Xcode)

```bash
git clone https://github.com/wstaszczyk/ClaudeUsage.git
cd ClaudeUsage/ClaudeUsage
./deploy.sh
```

This builds a Release binary, installs it to `/Applications/ClaudeUsage.app`, and launches it. The menu bar entry appears within a few seconds.

The first launch will trigger a macOS Keychain prompt:

> *"ClaudeUsage" wants to access "Claude Safe Storage" in your keychain*

Click **Always Allow**. The app needs this to decrypt your local Claude Desktop session cookie.

### Step-by-step (if you've never used Xcode)

See [`ClaudeUsage/ClaudeUsage/SETUP.md`](ClaudeUsage/ClaudeUsage/SETUP.md) for a full walkthrough — installing Xcode, creating the project, linking SQLite, and running.

---

## Troubleshooting

**Menu bar shows `⚠` instead of a percentage**
Open Claude Desktop and let it sync. The app reads Claude Desktop's session cookie; if Claude Desktop hasn't been opened recently the cookie is expired.

**Menu bar shows `~27%` with an "Estimated · open Claude Desktop to sync" note**
The API session cookie has expired and the app fell back to reading local JSONL files. It's approximate (±~5%) and the weekly section won't show percentages. Open Claude Desktop to refresh.

**Keychain prompt keeps appearing on every refresh**
You clicked "Allow" instead of "Always Allow". Open Keychain Access, find `Claude Safe Storage`, open the **Access Control** tab, add `ClaudeUsage.app` to the allowed list — or delete the entry and re-run the app, clicking "Always Allow" this time.

**Build fails with "module 'CommonCrypto' not found"**
Make sure the Xcode project's deployment target is set to macOS 13.0 or later.

**App still appears in the Dock**
The `Application is agent (UIElement)` Info.plist key must be `YES` — see step 8 of [`SETUP.md`](ClaudeUsage/ClaudeUsage/SETUP.md).

---

## Known limitations

- **Undocumented API.** The endpoint may change or disappear without notice.
- **Session cookie expires daily.** Opening Claude Desktop refreshes it automatically; there is no programmatic refresh path that doesn't involve full OAuth (whose client_id isn't extractable).
- **Weekly data unavailable in fallback.** When the API is unreachable, the app shows the 5-hour block as approximate and a raw 7-day token count under "All models" instead of a percentage (no weekly limit is exposed in `~/.claude.json`).
- **`kelp_forest_sonnet` is an undocumented key** in `~/.claude.json` and may be renamed in future Claude Desktop releases.

---

## Contributing

Issues and pull requests welcome. Especially valuable:

- Reports when Claude Desktop updates break the cookie decryption or API contract
- A way to read the weekly token limit from local data (would let the fallback show a percentage)
- A reliable programmatic refresh path for the session cookie

Please don't open issues asking Anthropic to make this official — they haven't, and they may not want to.

---

## License

[MIT](LICENSE) — do what you want with it, no warranty.

---

## Disclaimer

This project is not affiliated with Anthropic. "Claude" is a trademark of Anthropic, PBC. This app is a third-party, unsupported, best-effort tool for personal use.
