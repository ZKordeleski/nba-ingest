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


def _safe_str(value) -> Optional[str]:
    """Convert a value to a stripped non-empty string, or None.

    pd.isna() catches numpy NaN, which str() otherwise renders as "nan".
    """
    if pd.isna(value):
        return None
    s = str(value).strip()
    return s or None


def _safe_int(value) -> Optional[int]:
    f = _safe_float(value)
    return int(f) if f is not None else None


def _flatten_columns(df: pd.DataFrame) -> pd.DataFrame:
    """Flatten MultiIndex column headers, prefixing duplicates with their section.

    The draft table has multiple sections sharing short names (e.g., both
    'Totals' and 'Per Game' have a 'PTS' column). A naive last-level flatten
    produces duplicate column names, making row.get("PTS") return a Series.
    We prefix duplicate short names with their section: 'per_game_PTS'.
    """
    if not isinstance(df.columns, pd.MultiIndex):
        return df
    short_names = [str(col[-1]) if isinstance(col, tuple) else str(col) for col in df.columns]
    counts: dict[str, int] = {}
    for s in short_names:
        counts[s] = counts.get(s, 0) + 1
    new_cols = []
    for col in df.columns:
        if isinstance(col, tuple):
            short = str(col[-1])
            if counts[short] > 1 and len(col) > 1:
                section = str(col[-2]).lower().replace(" ", "_")
                new_cols.append(f"{section}_{short}")
            else:
                new_cols.append(short)
        else:
            new_cols.append(str(col))
    df.columns = new_cols
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
            "player_name": _safe_str(row.get("Player")),
            "team_abbr": _safe_str(row.get("Tm", row.get("Team"))),
            "college": _safe_str(row.get("College")),
            "career_games": _safe_int(row.get("G")),
            "career_pts_per_game": _safe_float(row.get("per_game_PTS")),
            "career_reb_per_game": _safe_float(row.get("per_game_TRB")),
            "career_ast_per_game": _safe_float(row.get("per_game_AST")),
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
