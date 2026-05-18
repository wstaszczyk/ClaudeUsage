#!/usr/bin/env python3
"""
claude_usage.py — Parse ~/.claude/projects JSONL files and report Claude Code usage.

Primary output: current 5-hour block % used and exact reset time.

Usage:
    python3 claude_usage.py           # current block status (default)
    python3 claude_usage.py -H 24     # last 24 hours breakdown
    python3 claude_usage.py -H 1      # last hour
    python3 claude_usage.py --today   # since local midnight
    python3 claude_usage.py --session <uuid>  # single session only

Data source:  ~/.claude/projects/<project-hash>/<session-uuid>.jsonl
Block limit:  ~/.claude.json → clientDataCache.kelp_forest_sonnet
              (verified May 2026; key name may change in future releases)

Schema notes (verified May 2026, Claude Code v2.1.138):
    - message.usage.input_tokens       UNRELIABLE — streaming placeholder (1–3)
    - message.usage.cache_creation_input_tokens  ✓ accurate
    - message.usage.cache_read_input_tokens      ✓ accurate
    - message.usage.output_tokens                ✓ accurate
    - Same (requestId, message.id) appears 2–3× per turn (streaming flush) → dedupe
    - Block usage metric = cache_creation_input_tokens + output_tokens
    - This matches what Claude Code desktop uses for the "X% · resets Nh" display

Block detection algorithm:
    Walk backwards from the most recent turn; a block boundary is any gap
    > 5 hours between consecutive turns. The current block is the maximal
    run of turns ending at the most recent turn with no such gap.
"""

from __future__ import annotations

import json
import sys
import argparse
from pathlib import Path
from datetime import datetime, timezone, timedelta
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional


# ─── Pricing table ($ / 1,000,000 tokens, API list price) ──────────────────
# Match by startswith(prefix). Most-specific prefix wins.
# Source: https://platform.claude.com/docs/models-overview
PRICES: dict[str, dict[str, float]] = {
    "claude-opus-4":    {"input": 15.00, "cache_write": 18.75, "cache_read": 1.50,  "output": 75.00},
    "claude-sonnet-4":  {"input":  3.00, "cache_write":  3.75, "cache_read": 0.30,  "output": 15.00},
    "claude-haiku-4":   {"input":  0.80, "cache_write":  1.00, "cache_read": 0.08,  "output":  4.00},
    "_default":         {"input":  3.00, "cache_write":  3.75, "cache_read": 0.30,  "output": 15.00},
}

def _price(model: str, key: str) -> float:
    for prefix, table in PRICES.items():
        if prefix == "_default":
            continue
        if model.startswith(prefix):
            return table.get(key, 0.0)
    return PRICES["_default"].get(key, 0.0)


# ─── Core data type ─────────────────────────────────────────────────────────

@dataclass
class UsageRecord:
    ts: datetime
    model: str
    session_id: str
    cwd: str
    cache_create: int = 0   # cache_creation_input_tokens (accurate)
    cache_read: int = 0     # cache_read_input_tokens (accurate)
    output: int = 0         # output_tokens (accurate)
    raw_input: int = 0      # input_tokens (UNRELIABLE placeholder, kept for debug)

    @property
    def block_usage_tokens(self) -> int:
        """Tokens that count toward the 5h block limit (matches Claude Code desktop)."""
        return self.cache_create + self.output

    @property
    def cost_usd(self) -> float:
        return (
            (self.cache_create / 1e6) * _price(self.model, "cache_write")
            + (self.cache_read / 1e6) * _price(self.model, "cache_read")
            + (self.output / 1e6) * _price(self.model, "output")
        )

    @property
    def total_tokens(self) -> int:
        return self.cache_create + self.cache_read + self.output


# ─── Block limit from ~/.claude.json ────────────────────────────────────────

@dataclass
class PlanInfo:
    limit: Optional[int]      # block token limit (None = unknown)
    org_type: str             # e.g. "claude_pro", "claude_max"
    source: str               # description of where limit came from

def read_plan_info() -> PlanInfo:
    """Read block limit from ~/.claude.json (clientDataCache.kelp_forest_sonnet)."""
    try:
        p = Path.home() / ".claude.json"
        d = json.loads(p.read_bytes())
        cache = d.get("clientDataCache", {})
        org_type = d.get("oauthAccount", {}).get("organizationType", "unknown")

        # Try known limit keys (most specific first)
        for key in ("kelp_forest_sonnet", "kelp_forest_opus", "kelp_forest_haiku"):
            val = cache.get(key)
            if val is not None:
                return PlanInfo(
                    limit=int(val),
                    org_type=org_type,
                    source=f"clientDataCache.{key}",
                )
        return PlanInfo(limit=None, org_type=org_type, source="not found in clientDataCache")
    except Exception as e:
        return PlanInfo(limit=None, org_type="unknown", source=f"error: {e}")


# ─── Block detection ────────────────────────────────────────────────────────

@dataclass
class BlockStatus:
    start: datetime
    end: datetime           # start + 5h (= reset time)
    turns: list             # UsageRecords in this block
    usage_tokens: int       # cache_create + output (counts toward limit)
    pct: Optional[float]    # usage_tokens / limit * 100 (None if limit unknown)
    plan: PlanInfo
    sync_status: str        # "synced" | "stale" | "no_data"

    @property
    def time_remaining(self) -> timedelta:
        return self.end - datetime.now(timezone.utc)

    @property
    def resets_at_local(self) -> str:
        return self.end.astimezone().strftime("%H:%M")

    @property
    def elapsed(self) -> timedelta:
        return datetime.now(timezone.utc) - self.start


def find_current_block(records: list, plan: PlanInfo) -> BlockStatus:
    """
    Find the current 5h block from all records (not window-filtered).
    A block is the maximal run of turns ending at the most recent turn
    with no consecutive gap exceeding 5 hours between adjacent turns.
    """
    if not records:
        now = datetime.now(timezone.utc)
        return BlockStatus(
            start=now, end=now + timedelta(hours=5),
            turns=[], usage_tokens=0, pct=None,
            plan=plan, sync_status="no_data",
        )

    sorted_recs = sorted(records, key=lambda r: r.ts)
    block: list = [sorted_recs[-1]]
    for rec in reversed(sorted_recs[:-1]):
        gap = (block[-1].ts - rec.ts).total_seconds() / 3600
        if gap > 5:
            break
        block.insert(0, rec)

    block_start = block[0].ts
    block_end = block_start + timedelta(hours=5)
    usage_tokens = sum(r.block_usage_tokens for r in block)
    pct = (usage_tokens / plan.limit * 100) if plan.limit else None

    # Sync status: is data fresh?
    newest_ts = block[-1].ts
    age_seconds = (datetime.now(timezone.utc) - newest_ts).total_seconds()
    if age_seconds < 120:
        sync_status = "synced"
    elif age_seconds < 3600:
        sync_status = "stale"    # idle but recently active
    else:
        sync_status = "stale"    # Claude Code may not be running

    return BlockStatus(
        start=block_start, end=block_end, turns=block,
        usage_tokens=usage_tokens, pct=pct,
        plan=plan, sync_status=sync_status,
    )


# ─── Parsing ────────────────────────────────────────────────────────────────

def parse_records(
    hours: float = 5.0,
    since: Optional[datetime] = None,
    session_filter: Optional[str] = None,
) -> list[UsageRecord]:
    """Return deduplicated UsageRecords within the time window."""
    projects_dir = Path.home() / ".claude" / "projects"
    if not projects_dir.exists():
        return []

    cutoff = since if since is not None else (
        datetime.now(timezone.utc) - timedelta(hours=hours)
    )

    # (requestId, msg_id) -> latest UsageRecord for deduplication
    seen: dict[tuple, UsageRecord] = {}
    files_scanned = 0

    for jsonl_path in sorted(projects_dir.rglob("*.jsonl")):
        files_scanned += 1
        try:
            _scan_file(jsonl_path, cutoff, seen, session_filter)
        except Exception:
            pass  # never let one bad file kill the run

    return sorted(seen.values(), key=lambda r: r.ts)


def _scan_file(
    path: Path,
    cutoff: datetime,
    seen: dict,
    session_filter: Optional[str],
) -> None:
    with open(path, "rb") as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue

            # Timestamp filter
            ts_str = obj.get("timestamp")
            if not ts_str:
                continue
            try:
                # Python 3.9 fromisoformat doesn't handle trailing Z
                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            except ValueError:
                continue

            if ts < cutoff:
                continue

            # Session filter (optional)
            session_id = obj.get("sessionId") or ""
            if session_filter and session_id != session_filter:
                continue

            # Must be an assistant message with a usage block
            msg = obj.get("message")
            if not isinstance(msg, dict):
                continue
            usage = msg.get("usage")
            if not isinstance(usage, dict):
                continue
            if msg.get("role") != "assistant":
                continue

            # Dedupe key: (requestId, message.id)
            request_id = obj.get("requestId") or ""
            msg_id = msg.get("id") or ""
            key = (request_id, msg_id)

            record = UsageRecord(
                ts=ts,
                model=msg.get("model") or "unknown",
                session_id=session_id,
                cwd=obj.get("cwd") or "",
                cache_create=int(usage.get("cache_creation_input_tokens") or 0),
                cache_read=int(usage.get("cache_read_input_tokens") or 0),
                output=int(usage.get("output_tokens") or 0),
                raw_input=int(usage.get("input_tokens") or 0),
            )

            # Keep the latest copy of each (requestId, msg_id) pair
            existing = seen.get(key)
            if existing is None or ts >= existing.ts:
                seen[key] = record


# ─── Formatting ─────────────────────────────────────────────────────────────

def _short_project(cwd: str) -> str:
    if not cwd:
        return "(unknown)"
    p = Path(cwd)
    try:
        parts = p.relative_to(Path.home()).parts
    except ValueError:
        parts = p.parts[-3:]
    display = "/".join(parts[-3:]) if len(parts) > 3 else "/".join(parts)
    return f"~/{display}"


def _fmt_n(n: int) -> str:
    return f"{n:>10,}"


def _fmt_cost(c: float) -> str:
    return f"${c:>6.2f}"


def _mins_ago(ts: datetime) -> str:
    delta = datetime.now(timezone.utc) - ts
    m = int(delta.total_seconds() / 60)
    if m < 60:
        return f"{m}m ago"
    h = m // 60
    return f"{h}h {m % 60}m ago"


def format_block_header(block: BlockStatus) -> str:
    """Format the primary block status — the most important output."""
    lines: list[str] = []
    lines.append("Claude Code — Current 5h Block")
    lines.append("═" * 52)

    if block.sync_status == "no_data":
        lines.append("  No usage data found. Have you run Claude Code yet?")
        lines.append(f"  Expected location: ~/.claude/projects/")
        return "\n".join(lines)

    # Progress bar (40 chars wide)
    pct = block.pct if block.pct is not None else 0.0
    pct_clamped = min(pct, 100.0)
    filled = int(40 * pct_clamped / 100)
    bar = "█" * filled + "░" * (40 - filled)

    if block.pct is not None:
        pct_str = f"{pct:.1f}%"
    else:
        pct_str = "?% (limit unknown)"

    tr = block.time_remaining
    if tr.total_seconds() > 0:
        tr_h = int(tr.total_seconds() // 3600)
        tr_m = int((tr.total_seconds() % 3600) // 60)
        reset_str = f"resets at {block.resets_at_local}  ({tr_h}h {tr_m}m)"
    else:
        reset_str = "block elapsed — next turn starts new block"

    lines.append(f"  {bar}")
    lines.append(f"  {pct_str:<20} {reset_str}")
    lines.append(f"  {block.usage_tokens:,} / {block.plan.limit:,} tokens used"
                 if block.plan.limit else
                 f"  {block.usage_tokens:,} tokens used  (limit unknown — check clientDataCache)")
    lines.append("")
    lines.append(f"  Block started: {block.start.astimezone().strftime('%H:%M:%S')}")
    lines.append(f"  Turns in block: {len(block.turns)}")
    lines.append(f"  Plan: {block.plan.org_type}")

    if block.sync_status == "stale":
        newest_ts = block.turns[-1].ts if block.turns else block.start
        age_m = int((datetime.now(timezone.utc) - newest_ts).total_seconds() / 60)
        lines.append(f"  ⚠ OUT OF SYNC — last turn was {age_m}m ago (Claude Code may not be running)")

    return "\n".join(lines)


def format_report(records: list[UsageRecord], window_hours: float, since: datetime) -> str:
    if not records:
        return "No Claude Code usage found in the specified window.\n"

    lines: list[str] = []
    since_local = since.astimezone()
    newest = records[-1]
    oldest = records[0]

    # ── Header ──────────────────────────────────────────────────────────────
    title = f"Claude Code Usage — last {window_hours:.0f}h"
    lines.append(title)
    lines.append("═" * 72)
    lines.append(
        f"Window start : {since_local.strftime('%Y-%m-%d %H:%M')} local"
        f"  ({_mins_ago(since)} | {int(window_hours)}h window)"
    )
    lines.append(
        f"First turn   : {oldest.ts.astimezone().strftime('%H:%M:%S')}  "
        f"Last turn: {newest.ts.astimezone().strftime('%H:%M:%S')}"
        f"  ({_mins_ago(newest.ts)})"
    )
    lines.append(f"Total turns  : {len(records)}")
    lines.append("")

    # ── By model ────────────────────────────────────────────────────────────
    model_stats: dict[str, dict] = defaultdict(lambda: {
        "turns": 0, "create": 0, "read": 0, "output": 0, "cost": 0.0
    })
    for r in records:
        s = model_stats[r.model]
        s["turns"] += 1
        s["create"] += r.cache_create
        s["read"] += r.cache_read
        s["output"] += r.output
        s["cost"] += r.cost_usd

    col = "{:<28} {:>6} {:>12} {:>12} {:>12} {:>8}"
    lines.append(col.format("MODEL", "TURNS", "CACHE_CREATE", "CACHE_READ", "OUTPUT", "COST"))
    lines.append("─" * 72)

    total_turns = total_create = total_read = total_output = 0
    total_cost = 0.0

    for model, s in sorted(model_stats.items()):
        lines.append(col.format(
            model[:28],
            s["turns"],
            f"{s['create']:,}",
            f"{s['read']:,}",
            f"{s['output']:,}",
            _fmt_cost(s["cost"]),
        ))
        total_turns += s["turns"]
        total_create += s["create"]
        total_read += s["read"]
        total_output += s["output"]
        total_cost += s["cost"]

    lines.append("─" * 72)
    lines.append(col.format(
        "TOTAL",
        total_turns,
        f"{total_create:,}",
        f"{total_read:,}",
        f"{total_output:,}",
        _fmt_cost(total_cost),
    ))
    lines.append("")
    lines.append(
        "⚠ CACHE_CREATE and CACHE_READ are accurate. OUTPUT is accurate."
    )
    lines.append(
        "  Cost shown is API-equivalent estimate only (Pro/Max = flat subscription)."
    )
    lines.append("")

    # ── By project (top 5) ──────────────────────────────────────────────────
    project_stats: dict[str, dict] = defaultdict(lambda: {"turns": 0, "output": 0})
    for r in records:
        key = _short_project(r.cwd)
        project_stats[key]["turns"] += 1
        project_stats[key]["output"] += r.output

    sorted_projects = sorted(project_stats.items(), key=lambda x: -x[1]["turns"])
    lines.append("By project (turns):")
    for proj, s in sorted_projects[:5]:
        bar_len = int(30 * s["turns"] / total_turns)
        bar = "█" * bar_len + "░" * (30 - bar_len)
        pct = 100 * s["turns"] / total_turns
        lines.append(f"  {proj:<40} {bar} {s['turns']:>4} turns ({pct:.0f}%)")
    if len(sorted_projects) > 5:
        rest = sum(s["turns"] for _, s in sorted_projects[5:])
        lines.append(f"  … {len(sorted_projects)-5} more projects               {rest} turns")
    lines.append("")

    # ── By session (for /cost cross-check) ──────────────────────────────────
    session_stats: dict[str, dict] = defaultdict(lambda: {
        "turns": 0, "create": 0, "read": 0, "output": 0, "cost": 0.0,
        "first_ts": None, "last_ts": None, "cwd": ""
    })
    for r in records:
        s = session_stats[r.session_id]
        s["turns"] += 1
        s["create"] += r.cache_create
        s["read"] += r.cache_read
        s["output"] += r.output
        s["cost"] += r.cost_usd
        s["cwd"] = r.cwd
        if s["first_ts"] is None or r.ts < s["first_ts"]:
            s["first_ts"] = r.ts
        if s["last_ts"] is None or r.ts > s["last_ts"]:
            s["last_ts"] = r.ts

    sorted_sessions = sorted(
        session_stats.items(),
        key=lambda x: -(x[1]["last_ts"].timestamp() if x[1]["last_ts"] else 0)
    )

    lines.append("By session (most recent first) — use this to cross-check /cost:")
    scol = "{:<38} {:>5} {:>12} {:>12} {:>12} {:>8}"
    lines.append(scol.format("SESSION UUID", "TURNS", "CACHE_CREATE", "CACHE_READ", "OUTPUT", "COST"))
    lines.append("─" * 72)
    for sess_id, s in sorted_sessions[:8]:
        short_id = sess_id[:36] if sess_id else "(no id)"
        lines.append(scol.format(
            short_id,
            s["turns"],
            f"{s['create']:,}",
            f"{s['read']:,}",
            f"{s['output']:,}",
            _fmt_cost(s["cost"]),
        ))
    if len(sorted_sessions) > 8:
        lines.append(f"  … and {len(sorted_sessions)-8} older sessions")
    lines.append("")

    # ── Tail: raw_input sanity check ─────────────────────────────────────────
    nonzero_raw = [r for r in records if r.raw_input > 10]
    if nonzero_raw:
        avg_raw = sum(r.raw_input for r in nonzero_raw) / len(nonzero_raw)
        lines.append(
            f"DEBUG: {len(nonzero_raw)} turns had raw_input > 10 (avg {avg_raw:.0f}). "
            "If consistently large, the input_tokens field may now be accurate."
        )

    return "\n".join(lines)


# ─── CLI ────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Claude Code usage tracker — reads ~/.claude/projects JSONL logs."
    )
    parser.add_argument(
        "-H", "--hours",
        type=float, default=None,
        help="Hours to look back for the detailed breakdown (default: shows current block only)",
    )
    parser.add_argument(
        "--today",
        action="store_true",
        help="Show detailed breakdown since local midnight",
    )
    parser.add_argument(
        "--session",
        metavar="UUID",
        help="Filter to a single session UUID (useful for /cost cross-check)",
    )
    args = parser.parse_args()

    plan = read_plan_info()

    # Always show the current block status first (reads ALL records for block detection)
    all_records = parse_records(hours=24 * 30)   # look back 30 days for block detection
    block = find_current_block(all_records, plan)
    print(format_block_header(block))
    print()

    # Optionally show detailed breakdown
    show_detail = args.hours is not None or args.today or args.session
    if show_detail:
        since: Optional[datetime] = None
        window_hours = args.hours or 5.0

        if args.today:
            today = datetime.now().astimezone().replace(
                hour=0, minute=0, second=0, microsecond=0
            )
            since = today.astimezone(timezone.utc)
            now = datetime.now(timezone.utc)
            window_hours = (now - since).total_seconds() / 3600

        records = parse_records(
            hours=window_hours,
            since=since,
            session_filter=args.session,
        )

        window_start = since if since is not None else (
            datetime.now(timezone.utc) - timedelta(hours=window_hours)
        )
        print(format_report(records, window_hours, window_start))


if __name__ == "__main__":
    main()
