#!/usr/bin/python3
# claude-usage.10s.py — SwiftBar plugin: Claude Code 5-hour usage tracker
#
# INSTALL
#   cp claude-usage.10s.py ~/Library/Application\ Support/SwiftBar/Plugins/
#   chmod +x ~/Library/Application\ Support/SwiftBar/Plugins/claude-usage.10s.py
#
# Data source: Anthropic internal API (same data the Claude Desktop app shows)
#   Endpoint:  https://api.anthropic.com/api/organizations/{uuid}/usage
#   Auth:      Session cookie from ~/Library/Application Support/Claude/Cookies
#              (decrypted using key from macOS Keychain "Claude Safe Storage")

from __future__ import annotations
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ── Zone thresholds and colors ───────────────────────────────────────────────
COLOR_CLEAR   = "#3b82f6"   # 0–74%
COLOR_WIND    = "#f59e0b"   # 75–89%
COLOR_FINISH  = "#ef4444"   # 90–100%
COLOR_MUTED   = "#888888"
COLOR_RED_SYS = "#ff453a"
COLOR_UNKNOWN = "#6b6b70"


# ── Session cookie decryption ────────────────────────────────────────────────

def _get_session_key() -> Optional[str]:
    """
    Decrypt the claude.ai sessionKey cookie from the Claude Desktop app's
    Chromium cookie database using the macOS Keychain key.
    Returns the full session key string, or None on failure.
    """
    try:
        # 1. Get the AES key from Keychain
        r = subprocess.run(
            ["security", "find-generic-password",
             "-s", "Claude Safe Storage", "-a", "Claude", "-w"],
            capture_output=True, text=True, timeout=5
        )
        if r.returncode != 0 or not r.stdout.strip():
            return None
        aes_key = hashlib.pbkdf2_hmac(
            "sha1",
            r.stdout.strip().encode("utf-8"),
            b"saltysalt", 1003, dklen=16
        )

        # 2. Read the encrypted cookie from Claude's SQLite cookie DB
        cookie_db = Path.home() / "Library/Application Support/Claude/Cookies"
        if not cookie_db.exists():
            return None

        conn = sqlite3.connect(str(cookie_db))
        row = conn.execute(
            "SELECT encrypted_value FROM cookies WHERE name='sessionKey'"
        ).fetchone()
        conn.close()
        if not row or not row[0]:
            return None

        enc_val: bytes = row[0]
        if enc_val[:3] != b"v10":
            return None

        # 3. Decrypt: v10 (3) + IV (16) + ciphertext
        iv = enc_val[3:19]
        ciphertext = enc_val[19:]

        with tempfile.NamedTemporaryFile(delete=False, suffix=".bin") as f:
            f.write(ciphertext)
            tmp = f.name

        try:
            result = subprocess.run(
                ["openssl", "enc", "-aes-128-cbc", "-d",
                 "-K", aes_key.hex(), "-iv", iv.hex(),
                 "-in", tmp, "-nosalt", "-nopad"],
                capture_output=True, timeout=5
            )
        finally:
            os.unlink(tmp)

        if result.returncode != 0:
            return None

        # Session key starts after first 16 bytes (first AES block)
        raw = result.stdout.decode("latin-1")
        m = re.search(r"sk-ant-sid\d+-[\w_\-]+", raw)
        return m.group(0) if m else None

    except Exception:
        return None


# ── API call ─────────────────────────────────────────────────────────────────

def fetch_usage() -> Optional[dict]:
    """
    Call the Anthropic internal usage API and return the parsed JSON.
    Returns None if the call fails or auth is invalid.
    """
    try:
        session_key = _get_session_key()
        if not session_key:
            return None

        # Org UUID lives in ~/.claude.json
        claude_json = Path.home() / ".claude.json"
        org_uuid = json.loads(claude_json.read_bytes()).get(
            "oauthAccount", {}
        ).get("organizationUuid", "")
        if not org_uuid:
            return None

        url = f"https://api.anthropic.com/api/organizations/{org_uuid}/usage"
        result = subprocess.run(
            ["curl", "-s", url,
             "-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
             "-H", "Accept: application/json",
             "-H", f"Cookie: sessionKey={session_key}; lastActiveOrg={org_uuid}"],
            capture_output=True, text=True, timeout=8
        )

        if result.returncode != 0 or not result.stdout.strip():
            return None

        data = json.loads(result.stdout)
        # Return None if we get an error response
        if "error" in data:
            return None
        return data

    except Exception:
        return None


# ── Formatting ────────────────────────────────────────────────────────────────

def _fmt_time_local(iso_str: str) -> str:
    """Convert ISO timestamp to local HH:MM (24h, no zero-pad on hours)."""
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        local = dt.astimezone()
        return f"{local.hour}:{local.minute:02d}"
    except Exception:
        return "--:--"


def _fmt_reset_day_time(iso_str: str) -> str:
    """
    Format reset time for weekly limits.
    - Within 24 hours: just the local time, e.g. '17:00'
    - More than 24 hours: weekday + time, e.g. 'Mon 17:00'
    """
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        local = dt.astimezone()
        time_str = f"{local.hour}:{local.minute:02d}"
        secs_until = (dt - datetime.now(timezone.utc)).total_seconds()
        if secs_until <= 86400:          # within 24 hours — time only
            return time_str
        else:                            # more than 24 hours — day + time
            return f"{local.strftime('%a')} {time_str}"
    except Exception:
        return "--"


def _fmt_remaining(iso_str: str) -> str:
    """Return 'Xh Ym' until the given ISO timestamp."""
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        secs = int((dt - datetime.now(timezone.utc)).total_seconds())
        if secs <= 0:
            return "now"
        h, m = secs // 3600, (secs % 3600) // 60
        return f"{h}h {m}m" if h else f"{m}m"
    except Exception:
        return "--"


def _zone_color(pct: float) -> str:
    if pct >= 90:
        return COLOR_FINISH
    if pct >= 75:
        return COLOR_WIND
    return COLOR_CLEAR


def _bar(pct: float, width: int = 20) -> str:
    filled = round(width * min(pct, 100) / 100)
    return "█" * filled + "░" * (width - filled)


# ── SwiftBar output ───────────────────────────────────────────────────────────

def render(usage: Optional[dict]) -> str:
    rows: list[str] = []

    def row(text: str, **kw) -> None:
        params = " ".join(f"{k}={v}" for k, v in kw.items())
        rows.append(f"{text} | {params}" if params else text)

    def div() -> None:
        rows.append("---")

    # ── No data / error ───────────────────────────────────────────────────────
    if not usage:
        rows.append("?")
        div()
        rows.append("No usage data — Claude Desktop must be running.")
        row("Session refreshes automatically while Claude Desktop is open.",
            color=COLOR_MUTED, size="12")
        div()
        row("Refresh", bash=__file__, terminal="false", refresh="true")
        div()
        row("Quit", quit="true", color=COLOR_RED_SYS)
        return "\n".join(rows)

    # ── Parse five_hour block ─────────────────────────────────────────────────
    five = usage.get("five_hour") or {}
    pct: Optional[float] = five.get("utilization")
    resets_at: str = five.get("resets_at", "")

    reset_time_local = _fmt_time_local(resets_at)
    remaining = _fmt_remaining(resets_at)

    # ── Title line ───────────────────────────────────────────────────────────
    if pct is None:
        rows.append("-- · --:--")
    elif pct >= 90:
        rows.append(f"⚠ {pct:.0f}% · {reset_time_local}")
    elif pct >= 75:
        rows.append(f"◑ {pct:.0f}% · {reset_time_local}")
    else:
        rows.append(f"{pct:.0f}% · {reset_time_local}")

    div()

    # ── Dropdown content ─────────────────────────────────────────────────────
    row("5-hour limit", size="11", color=COLOR_MUTED)

    if pct is not None:
        clr = _zone_color(pct)
        row(f"{_bar(pct)}  {pct:.0f}%", font="Menlo", color=clr)
    else:
        row("░░░░░░░░░░░░░░░░░░░░  --%", font="Menlo", color=COLOR_UNKNOWN)

    rows.append(f"Resets at {reset_time_local}  ·  {remaining} remaining")

    # ── Weekly metrics (if present) ───────────────────────────────────────────
    seven = usage.get("seven_day") or {}
    seven_pct: Optional[float] = seven.get("utilization")
    seven_resets: str = seven.get("resets_at", "")

    omelette = usage.get("seven_day_omelette") or {}
    om_pct: Optional[float] = omelette.get("utilization")

    if seven_pct is not None or om_pct is not None:
        div()
        # Reset time: use seven_day's timestamp (both limits share the same window)
        om_resets: str = (usage.get("seven_day_omelette") or {}).get("resets_at", "")
        weekly_resets = seven_resets or om_resets
        weekly_reset_str = f"  · resets {_fmt_reset_day_time(weekly_resets)}" if weekly_resets else ""
        row(f"Weekly usage{weekly_reset_str}", size="11", color=COLOR_MUTED)
        if seven_pct is not None:
            seven_bar = _bar(seven_pct, 10)
            rows.append(f"  All models    {seven_bar} {seven_pct:.0f}%")
        if om_pct is not None:
            om_bar = _bar(om_pct, 10)
            rows.append(f"  Claude Design  {om_bar} {om_pct:.0f}%")

    div()

    row("Refresh", bash=__file__, terminal="false", refresh="true")
    row("Open Anthropic Console", href="https://console.anthropic.com/usage")
    div()
    row("Quit", quit="true", color=COLOR_RED_SYS)

    return "\n".join(rows)


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    usage = fetch_usage()
    print(render(usage))


if __name__ == "__main__":
    main()
