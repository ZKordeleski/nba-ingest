"""Flatten Basketball-Reference draft class DataFrames into FLAT schema dicts.

Draft pages (/draft/NBA_{year}.html) have a "stats" table with multi-level
column headers. The table lists every pick with the team that drafted them,
their organization, and career stats as of the page fetch time.

This data is refreshed weekly by the weekly_meta job (Slice 5 scope).
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Optional

import pandas as pd

logger = logging.getLogger(__name__)


def _safe_float(value) -> Optional[float]:
    if pd.isna(value) or value in ("", "N/A"):
        return None
    try:
        return float(str(value).replace("%", ""))
    except (ValueError, TypeError):
        return None


def _safe_int(value) -> Optional[int]:
    f = _safe_float(value)
    return int(f) if f is not None else None


def _flatten_columns(df: pd.DataFrame) -> pd.DataFrame:
    """Flatten MultiIndex column headers."""
    if isinstance(df.columns, pd.MultiIndex):
        # Take the innermost level for the column name.
        df.columns = [col[-1] if isinstance(col, tuple) else col for col in df.columns]
    return df


def _now_utc() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def flatten_draft_career_stats(year: int, df: pd.DataFrame) -> list[dict]:
    """Map a draft class DataFrame to draft_career_stats rows.

    Skips header rows that repeat inside the table body (BR includes these
    every ~20 rows for readability).

    Args:
        year: The draft year (e.g., 2023).
        df: Raw DataFrame from the BR draft stats table.

    Returns:
        List of dicts, one per draft pick.
    """
    if df is None or df.empty:
        return []

    df = _flatten_columns(df.copy())
    rows = []
    now = _now_utc()

    for _, row in df.iterrows():
        # Skip header rows (pick column contains "Pk" or is NaN).
        pick_val = row.get("Pk", row.get("Pick", row.get("Rk")))
        if pd.isna(pick_val) or str(pick_val).strip() in ("Pk", "Pick", "Rk", ""):
            continue

        overall_pick = _safe_int(pick_val)
        if overall_pick is None:
            continue

        rows.append({
            "season": year,
            "overall_pick": overall_pick,
            "player_name": str(row.get("Player", "")).strip() or None,
            "team_abbr": str(row.get("Tm", row.get("Team", ""))).strip() or None,
            "college": str(row.get("College", "")).strip() or None,
            "career_games": _safe_int(row.get("G")),
            "career_pts_per_game": _safe_float(row.get("PTS")),
            "career_reb_per_game": _safe_float(row.get("TRB")),
            "career_ast_per_game": _safe_float(row.get("AST")),
            "career_fg_pct": _safe_float(row.get("FG%")),
            "career_fg3_pct": _safe_float(row.get("3P%")),
            "career_ft_pct": _safe_float(row.get("FT%")),
            "career_win_shares": _safe_float(row.get("WS")),
            "career_ws_per_48": _safe_float(row.get("WS/48")),
            "career_bpm": _safe_float(row.get("BPM")),
            "career_vorp": _safe_float(row.get("VORP")),
            "fetched_at": now,
        })

    return rows
