# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Product

**Job story:** When working in Claude Code, glance at the menu bar to know how much of the 5-hour plan budget is burned and when it resets — without breaking flow.

**Key design decisions (from Layers sessions):**
- Primary signal: % used + exact reset clock time (not relative "2h")
- Cost in dollars: intentionally excluded (Pro/Max is flat-rate)
- 3 zones: Clear 0–74% 🟢, Wind-down 75–89% 🟡, Finish 90–100% 🔴
- Weekly limits (all models + Claude Design) shown as secondary section
- Reset time: exact clock when >24h away, day+time when within 24h

**Conceptual model:** Turn → Session → Block (5h window) → Project. See `DESIGN_BRIEF.md`.
**UI spec (all states + dark card mockups):** `Token Usage States.html` — open in browser.

---

## Architecture

```
ClaudeUsageApp.swift   @main · MenuBarExtra · emoji dot + title in menu bar label
UsageViewModel.swift   @Observable · 30s timer · LoadState · all formatting helpers
UsageService.swift     struct · fetch() = API-first with JSONL fallback
MenuBarView.swift      SwiftUI popover · DS{} design token enum at top of file
```

**Data flow:** `UsageService.fetch()` → live API → on failure → JSONL files → `LoadState` → UI.
`LoadState.loaded` carries `isApproximate: Bool` — true on JSONL fallback.

---

## Build & deploy

```bash
cd ClaudeUsage && ./deploy.sh          # builds Release, installs to /Applications, relaunches
```
Full Xcode setup: `ClaudeUsage/ClaudeUsage/SETUP.md`.

---

## Data sources

**API (primary — exact match to Claude Desktop):**
- `GET https://api.anthropic.com/api/organizations/{uuid}/usage`
- Returns `five_hour.utilization`, `five_hour.resets_at`, `seven_day.*`, `seven_day_omelette.*`
- Auth: decrypt `sessionKey` cookie from `~/Library/Application Support/Claude/Cookies`
  - AES-128-CBC · key = PBKDF2-HMAC-SHA1(Keychain `Claude Safe Storage`, `saltysalt`, 1003, 16B)
  - IV = bytes 3–18 of the `v10`-prefixed encrypted value
- Org UUID: `~/.claude.json → oauthAccount.organizationUuid`

**JSONL fallback (approximate — activates when API session expires):**
- `~/.claude/projects/**/*.jsonl`
- Block limit: `~/.claude.json → clientDataCache.kelp_forest_sonnet` (string, default 1 000 000)
- Usage metric: **`cache_creation_input_tokens` only** (not output, not cache_read)
- Dedup by `(requestId, message.id)` — turns appear 2–3× per streaming flush
- Block = greedy 5h walk backwards; gap > 5h = boundary
- Full derivation + verification history: `memory/project_block_limit_source.md`

---

## Implemented features

- Menu bar: `🟢/🟡/🔴 27% · 3:50` — emoji dot (preserves color; SwiftUI shapes don't in template mode)
- Dropdown: full-width progress bar · reset time · weekly all models · weekly Claude Design
- Graceful fallback: shows `~27%` + "Estimated · open Claude Desktop to sync" note
- Launch at Login toggle (SMAppService)
- Auto-refresh every 30s

---

## Important decisions

| Decision | Rationale |
|---|---|
| `@Observable` not `ObservableObject` | Swift 6 project with `-default-isolation=MainActor` |
| `ENABLE_APP_SANDBOX = NO` | Must read `~/Library/.../Claude/Cookies` and `~/.claude/` |
| Emoji for colored dot | SwiftUI `Circle().fill(color)` loses color in menu bar template mode |
| `cache_creation_input_tokens` only | Only field that matches Claude Desktop's quota; output does not count |
| API-first, JSONL fallback | API session cookie expires overnight; JSONL is ~5% approximate but always available |

---

## Unresolved issues

- **Weekly data unavailable in fallback** — JSONL has no weekly window concept; `seven_day` is `nil` when API fails.
- **`kelp_forest_sonnet` key is undocumented** — could change in future Claude Code releases; fallback to 1 000 000 if missing.
- **Session cookie expires daily** — opening Claude Desktop refreshes it; no programmatic refresh path found (OAuth client_id is compiled into Claude Desktop and not extractable).
- **No git repository** — project has no version control yet.

---

## Next recommended steps

1. `git init` in this directory — no history exists yet.
2. Add weekly JSONL fallback — approximate 7-day rollup from JSONL to populate `seven_day` when API fails.
3. Update `memory/project_block_limit_source.md` — formula listed there is wrong (says `cache_create + output`; correct is `cache_create` only).
