"""Flatten Basketball-Reference box score DataFrames into FLAT schema dicts.

All functions are pure (no I/O) and return list[dict] or dict for direct
insertion into ZK_NBA.FLAT.* tables.

Multi-level column headers from BR (tuples like ('Basic Box Score Stats', 'MP'))
are flattened to a single string before processing.

The totals row ("Team Totals") that BR appends to each box table is excluded.
"""

from __future__ import annotations

import logging
import re
from datetime import datetime, timezone
from typing import Optional

import pandas as pd

logger = logging.getLogger(__name__)


def _flatten_columns(df: pd.DataFrame) -> pd.DataFrame:
    """Flatten MultiIndex column headers to single strings.

    BR box tables have two-level headers. pd.read_html returns them as tuples
    like ('Basic Box Score Stats', 'MP'). We keep only the LAST element so
    lookups work with short names ('MP', 'PTS', 'FG', etc.).

    Taking the full joined string ('Basic Box Score Stats_MP') would break
    every stat lookup since the code accesses short names.
    """
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = [str(col[-1]) if isinstance(col, tuple) else str(col) for col in df.columns]
    return df


def _drop_totals_row(df: pd.DataFrame) -> pd.DataFrame:
    """Remove the 'Team Totals' row and any rows with no player name."""
    # The player column is typically the first column or named 'Player'.
    player_col = df.columns[0] if "Player" not in df.columns else "Player"
    df = df[df[player_col].notna()]
    df = df[~df[player_col].str.contains("Team Totals", na=False)]
    df = df[~df[player_col].str.startswith("Reserves", na=False)]
    df = df[~df[player_col].str.startswith("Starters", na=False)]
    return df.reset_index(drop=True)


def _safe_float(value) -> Optional[float]:
    """Convert a value to float, returning None if not parseable."""
    if pd.isna(value) or value in ("", "Did Not Play", "Did Not Dress", "Not With Team", "Player Suspended"):
        return None
    try:
        return float(value)
    except (ValueError, TypeError):
        return None


def _safe_int(value) -> Optional[int]:
    """Convert a value to int, returning None if not parseable."""
    f = _safe_float(value)
    return int(f) if f is not None else None


def _parse_minutes(mp_str) -> Optional[float]:
    """Parse BR minutes string 'MM:SS' to decimal minutes.

    Returns None for DNP strings or unparseable values.
    """
    if pd.isna(mp_str) or not isinstance(mp_str, str):
        return None
    if ":" in mp_str:
        parts = mp_str.split(":")
        try:
            return int(parts[0]) + int(parts[1]) / 60.0
        except (ValueError, IndexError):
            return None
    return _safe_float(mp_str)


def _now_utc() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


# ──────────────────────────────────────────────────────────────────────────────
# Public flatteners
# ──────────────────────────────────────────────────────────────────────────────


def flatten_player_box_basic(
    game_slug: str,
    team_abbr: str,
    df: pd.DataFrame,
    is_home: bool,
    game_date: Optional[str] = None,
) -> list[dict]:
    """Flatten a basic box score DataFrame into player_box_basic rows.

    Args:
        game_slug: BR game slug (e.g., "20231025ODAL").
        team_abbr: Team abbreviation for this side of the box (e.g., "DAL").
        df: Raw DataFrame from box-{TEAM}-game-basic table.
        is_home: True if this team is the home team.
        game_date: ISO date string (YYYY-MM-DD). Derived from slug if None.

    Returns:
        List of dicts, one per player (excludes DNPs and totals row).
    """
    if df is None or df.empty:
        return []

    # Infer game_date from slug if not provided (first 8 chars: YYYYMMDD).
    if game_date is None:
        game_date = f"{game_slug[:4]}-{game_slug[4:6]}-{game_slug[6:8]}"

    df = _flatten_columns(df.copy())
    df = _drop_totals_row(df)

    rows = []
    now = _now_utc()

    for _, row in df.iterrows():
        mp = _parse_minutes(row.get("MP"))
        # Skip rows where player didn't play (None minutes = did not play).
        # We still include DNP rows with 0.0 minutes per spec.
        if mp is None:
            mp = 0.0

        rows.append({
            "game_id": game_slug,   # BR slug used as game_id; remapped on MERGE if NBA IDs differ
            "player_id": None,      # BR doesn't expose player IDs in the HTML; mapped later via name
            "player_name": str(row.get("Player", row.iloc[0])).strip(),
            "team_id": None,
            "team_name": None,
            "team_abbr": team_abbr,
            "opponent_team_name": None,
            "game_date": game_date,
            "season": None,
            "game_type": None,
            "is_win": None,         # Determined after fetching both teams' line scores
            "is_home": is_home,
            "minutes_played": mp,
            "pts": _safe_int(row.get("PTS")),
            "ast": _safe_int(row.get("AST")),
            "reb": _safe_int(row.get("TRB")),
            "oreb": _safe_int(row.get("ORB")),
            "dreb": _safe_int(row.get("DRB")),
            "stl": _safe_int(row.get("STL")),
            "blk": _safe_int(row.get("BLK")),
            "tov": _safe_int(row.get("TOV")),
            "pf": _safe_int(row.get("PF")),
            "fgm": _safe_int(row.get("FG")),
            "fga": _safe_int(row.get("FGA")),
            "fg_pct": _safe_float(row.get("FG%")),
            "fg3m": _safe_int(row.get("3P")),
            "fg3a": _safe_int(row.get("3PA")),
            "fg3_pct": _safe_float(row.get("3P%")),
            "ftm": _safe_int(row.get("FT")),
            "fta": _safe_int(row.get("FTA")),
            "ft_pct": _safe_float(row.get("FT%")),
            "plus_minus": _safe_float(row.get("+/-")),
            "source": "br_scrape",
            "fetched_at": now,
        })

    return rows


def flatten_player_box_advanced(
    game_slug: str,
    team_abbr: str,
    df: pd.DataFrame,
) -> list[dict]:
    """Flatten an advanced box score DataFrame into player_box_advanced rows.

    Args:
        game_slug: BR game slug.
        team_abbr: Team abbreviation.
        df: Raw DataFrame from box-{TEAM}-game-advanced table.

    Returns:
        List of dicts, one per player.
    """
    if df is None or df.empty:
        return []

    df = _flatten_columns(df.copy())
    df = _drop_totals_row(df)

    rows = []
    now = _now_utc()

    for _, row in df.iterrows():
        rows.append({
            "game_id": game_slug,
            "player_id": None,       # Matched by player_name on MERGE
            "ts_pct": _safe_float(row.get("TS%")),
            "efg_pct": _safe_float(row.get("eFG%")),
            "fg3a_rate": _safe_float(row.get("3PAr")),
            "fta_rate": _safe_float(row.get("FTr")),
            "orb_pct": _safe_float(row.get("ORB%")),
            "drb_pct": _safe_float(row.get("DRB%")),
            "trb_pct": _safe_float(row.get("TRB%")),
            "ast_pct": _safe_float(row.get("AST%")),
            "stl_pct": _safe_float(row.get("STL%")),
            "blk_pct": _safe_float(row.get("BLK%")),
            "tov_pct": _safe_float(row.get("TOV%")),
            "usg_pct": _safe_float(row.get("USG%")),
            "ortg": _safe_int(row.get("ORtg")),
            "drtg": _safe_int(row.get("DRtg")),
            "bpm": _safe_float(row.get("BPM")),
            "fetched_at": now,
        })

    return rows


def flatten_line_score(game_slug: str, df: pd.DataFrame) -> Optional[dict]:
    """Flatten the line_score hidden table into a single line_scores row.

    The line_score table has 2 rows (one per team, away first, then home).

    Args:
        game_slug: BR game slug.
        df: DataFrame from the hidden line_score comment table.

    Returns:
        A single dict for line_scores, or None if df is None/empty.
    """
    if df is None or df.empty or len(df) < 2:
        logger.warning("line_score table missing or incomplete for %s", game_slug)
        return None

    df = _flatten_columns(df.copy())
    game_date = f"{game_slug[:4]}-{game_slug[4:6]}-{game_slug[6:8]}"

    # Row 0 = away team, row 1 = home team (BR convention: visitor listed first).
    away_row = df.iloc[0]
    home_row = df.iloc[1]

    def period_pts(row, col_name: str) -> Optional[int]:
        return _safe_int(row.get(col_name))

    return {
        "game_id": game_slug,
        "game_date": game_date,
        "home_team_abbr": str(home_row.iloc[0]).strip(),  # First col is team name/abbr
        "home_q1": period_pts(home_row, "1"),
        "home_q2": period_pts(home_row, "2"),
        "home_q3": period_pts(home_row, "3"),
        "home_q4": period_pts(home_row, "4"),
        "home_ot1": period_pts(home_row, "OT") or period_pts(home_row, "5"),
        "home_ot2": period_pts(home_row, "2OT") or period_pts(home_row, "6"),
        "home_ot3": period_pts(home_row, "3OT") or period_pts(home_row, "7"),
        "home_ot4": period_pts(home_row, "4OT") or period_pts(home_row, "8"),
        "home_pts": period_pts(home_row, "T"),
        "away_team_abbr": str(away_row.iloc[0]).strip(),
        "away_q1": period_pts(away_row, "1"),
        "away_q2": period_pts(away_row, "2"),
        "away_q3": period_pts(away_row, "3"),
        "away_q4": period_pts(away_row, "4"),
        "away_ot1": period_pts(away_row, "OT") or period_pts(away_row, "5"),
        "away_ot2": period_pts(away_row, "2OT") or period_pts(away_row, "6"),
        "away_ot3": period_pts(away_row, "3OT") or period_pts(away_row, "7"),
        "away_ot4": period_pts(away_row, "4OT") or period_pts(away_row, "8"),
        "away_pts": period_pts(away_row, "T"),
        "source": "br_scrape",
        "fetched_at": _now_utc(),
    }


def flatten_four_factors(game_slug: str, df: pd.DataFrame) -> list[dict]:
    """Flatten the four_factors hidden table into two dicts (home + away).

    Four factors: eFG%, TOV%, ORB%, FT/FGA for each team.

    Args:
        game_slug: BR game slug.
        df: DataFrame from the hidden four_factors comment table.

    Returns:
        List of up to 2 dicts (one per team). Empty list if df is None/empty.
    """
    if df is None or df.empty:
        return []

    df = _flatten_columns(df.copy())
    rows = []
    for _, row in df.iterrows():
        rows.append({
            "game_id": game_slug,
            "team_abbr": str(row.iloc[0]).strip(),
            "pace": _safe_float(row.get("Pace")),
            "efg_pct": _safe_float(row.get("eFG%")),
            "tov_pct": _safe_float(row.get("TOV%")),
            "orb_pct": _safe_float(row.get("ORB%")),
            "ft_per_fga": _safe_float(row.get("FT/FGA")),
            "ortg": _safe_int(row.get("ORtg")),
            "fetched_at": _now_utc(),
        })
    return rows


def flatten_game_meta(game_slug: str, meta: dict) -> dict:
    """Package the page metadata into a structured dict.

    Args:
        game_slug: BR game slug.
        meta: Dict from br_client._parse_meta (officials, inactives, attendance).

    Returns:
        Dict with structured meta fields.
    """
    return {
        "game_id": game_slug,
        "officials": meta.get("officials", []),
        "inactives": meta.get("inactives", []),
        "attendance": meta.get("attendance"),
        "fetched_at": _now_utc(),
    }
