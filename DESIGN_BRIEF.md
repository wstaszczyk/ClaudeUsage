# Claude Token Usage — Menu Bar App: Design Brief

Use this document as the complete context for generating a visual mockup of all UI states.
All decisions are final unless noted as "open". Do not invent new states or copy — use exactly what is specified here.

---

## What this product is

A tiny macOS menu bar app that shows how much of your Claude Code 5-hour usage budget you've burned, and exactly when it resets.

It lives permanently in the macOS menu bar as a short text string. Clicking it opens a small dropdown with more detail. There are no other screens.

**One job story:**
> "When I'm working in Claude Code, I want to glance at my menu bar and know roughly how much of my 5-hour budget I've burned and when it resets, so I can decide whether to keep going or pause — without breaking flow."

**Target user:** a developer using Claude Code daily on macOS, Pro or Max plan.

---

## Two places to design

### Place 1 — Menu bar item (always visible)

A short text string in the macOS menu bar. Always on screen.

**Hard constraint:** macOS menu bar title text is plain system text only. No color, no weight variation, no custom font. Visual differentiation must come entirely from glyphs and characters.

**Format:** `[glyph] [%] · [HH:MM]`
- `[glyph]` — zone indicator, present only in Wind-down and Finish zones
- `[%]` — whole number, no decimal
- `·` — middle dot separator (U+00B7)
- `[HH:MM]` — 24-hour local clock time, no zero-padding on hours (`9:45` not `09:45`)

### Place 2 — Detail dropdown (opens on click)

A vertical list of items that appears below the menu bar item when clicked. Closes when the user clicks outside or presses Escape.

---

## 3-zone model

Usage is divided into three zones based on % of the 5-hour block consumed.
Each zone changes the glyph in the menu bar title and the color of the progress bar in the dropdown.

| Zone | Range | Glyph | Bar color | Meaning |
|---|---|---|---|---|
| **Clear** | 0–74% | *(none)* | Blue `#3B82F6` | Proceed freely |
| **Wind-down** | 75–89% | `◑` | Amber `#F59E0B` | Wrap up; don't start heavy new tasks |
| **Finish** | 90–100% | `⚠` | Red `#EF4444` | Complete current thought; stop |

The glyph comes before the % with one space: `◑ 84% · 16:15`

---

## Complete surface spec

### Menu bar title strings (Place 1, all states)

| State | Exact string | When |
|---|---|---|
| Clear | `42% · 17:59` | 0–74%, data fresh |
| Wind-down | `◑ 84% · 16:15` | 75–89%, data fresh |
| Finish | `⚠ 94% · 16:06` | 90–100%, data fresh |
| Elapsed | `↺ ready` | Block ended >5h ago; waiting for new session |
| Stale | `~ 42% · 17:59` | Data not updated in >5 min (Claude Code may not be running) |
| No data | `?` | No Claude Code sessions found on this Mac |
| Limit unknown | `-- · 17:59` | % not computable; reset time still shown |
| Error | `⚠` | Parse or file-read failure |

---

### Dropdown content (Place 2, all states)

**Default dropdown (synced, any zone):**

```
┌─────────────────────────────────────────┐
│ 5-hour limit                            │  ← section label, small, muted
│ ████████████████░░░░  42%               │  ← progress bar, zone color
│ Resets at 17:59  ·  3h 54m remaining   │  ← reset time, prominent
├─────────────────────────────────────────┤
│ Block started 12:59  ·  47 turns        │  ← block metadata, secondary
├─────────────────────────────────────────┤
│ By model:                               │  ← label, small, muted
│   Opus 4.7        98k                   │
│   Sonnet 4.6     215k                   │
│   Haiku 4.5       116k                  │
├─────────────────────────────────────────┤
│ Refresh                                 │  ← action
│ Open Anthropic Console                  │  ← action, opens browser
├─────────────────────────────────────────┤
│ Quit                                    │  ← action
└─────────────────────────────────────────┘
```

**Progress bar construction:**
- 20 characters wide
- Filled: `█` (U+2588), Empty: `░` (U+2591)
- `filled_chars = round(20 × pct / 100)`
- Color applied to the entire bar+% line
- At 42%: `████████░░░░░░░░░░░░  42%` (blue)
- At 84%: `████████████████░░░░  84%` (amber)
- At 94%: `██████████████████░░  94%` (red)

**Stale state** — add banner above the bar:
```
│ ⚠ Data stale — Claude Code may not be running   │
│ Last update: 8m ago  ·  Start Claude Code to resume │
│ [bar line, same zone color but dimmed]          │
│ Resets at 17:59  ·  3h 54m remaining           │
│ ...rest same as default...                      │
```

**Elapsed state:**
```
│ Last block ended at 12:59                       │
│ Start Claude Code to begin a new one.           │
├─────────────────────────────────────────────────│
│ Refresh                                         │
│ Open Anthropic Console                          │
├─────────────────────────────────────────────────│
│ Quit                                            │
```

**No data state:**
```
│ No Claude Code sessions found.                  │
│ Run Claude Code to start tracking.              │
├─────────────────────────────────────────────────│
│ Quit                                            │
```

**Limit unknown state:**
```
│ 5-hour limit  (plan limit unavailable)          │
│ ░░░░░░░░░░░░░░░░░░░░  --%   [grey, dashed bar] │
│ Resets at 17:59  ·  3h 54m remaining           │
│ 429k tokens used this block                     │
│ Refreshes automatically when Claude Code starts.│
├─────────────────────────────────────────────────│
│ ...actions...                                   │
```

**Error state:**
```
│ ⚠ Error reading usage data                     │
│ [error message, 1 line]                         │
│ Try refreshing, or restart Claude Code.         │
├─────────────────────────────────────────────────│
│ Refresh                                         │
│ Quit                                            │
```

---

## Color palette

| Role | Hex | Where used |
|---|---|---|
| Clear (blue) | `#3B82F6` | Progress bar, Clear zone |
| Wind-down (amber) | `#F59E0B` | Progress bar, Wind-down zone |
| Finish (red) | `#EF4444` | Progress bar, Finish zone |
| Muted text | `#888888` | Section labels ("5-hour limit", "By model:") |
| All other text | system default | Titles, values, actions |
| Destructive (Quit) | system red | Quit action only |

All colors must work in both macOS light mode and dark mode.

---

## Typography

- Menu bar title: system font, regular weight, system size (~13pt) — no control in V1
- Dropdown section labels ("5-hour limit", "By model:"): small (~11pt), muted color `#888888`
- Dropdown body text: system font, regular weight (~13pt)
- Progress bar characters: monospace preferred for consistent bar width
- Model names: displayed as normalized short names (`Opus 4.7`, `Sonnet 4.6`, `Haiku 4.5`), not raw IDs

---

## Ubiquitous language (exact vocabulary — do not substitute)

| Use this | Not this |
|---|---|
| 5-hour limit | quota, budget, allowance, credit |
| Resets at | expires, refreshes, ends, renews |
| Block started | session started, period started |
| Turns | messages, requests, calls |
| By model | model breakdown, usage by model |
| Refresh | reload, update, sync |

---

## What to design (scope)

Design all of the following:
1. Menu bar item in all 8 states listed above (shown as a compact preview)
2. Default dropdown (Clear zone, synced) — full layout
3. Wind-down dropdown (75–89%) — bar color change + glyph
4. Finish dropdown (90–100%) — bar color change + glyph
5. Stale dropdown — with banner
6. Elapsed dropdown
7. No-data dropdown

## What NOT to design

- Settings screen (none in V1)
- Notifications / alerts (out of scope)
- History charts (out of scope)
- Onboarding flow (out of scope)
- Mobile / non-macOS (macOS only)

---

## Design ask for Claude Artifacts

Generate an HTML page that simulates all UI states side by side. The page should:

1. Show the menu bar item in each of its 8 states as compact chips across the top — simulating how they'd look in the macOS menu bar (dark background, light text, monospace or system font, ~13pt).

2. Below the chips, show the expanded dropdown for each key state (Default/Clear, Wind-down, Finish, Stale, Elapsed, No data) as individual cards.

3. Each dropdown card should:
   - Render the progress bar as a filled/empty block character bar with the correct zone color
   - Show reset time, block metadata, model breakdown, and action items
   - Match the exact copy and hierarchy from this document

4. Use a dark background (`#1C1C1E` or similar macOS-system-dark) for the dropdown cards to simulate the macOS dropdown appearance.

5. The page should be self-contained HTML — no external dependencies.

The goal is a visual reference for all states, not an interactive prototype.
