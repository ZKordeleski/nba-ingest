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
        raw_mp = _parse_minutes(row.get("MP"))
        is_dnp = raw_mp is None  # "Did Not Play" / "Did Not Dress" / "Player Suspended"
        mp = raw_mp if raw_mp is not None else 0.0

        # DNP players have 0 for all counting stats (not None). Percentage stats
        # remain None because 0/0 is undefined.  Matches seed SQL's COALESCE(..., 0).
        def _int(val: object) -> Optional[int]:
            return 0 if is_dnp else _safe_int(val)

        player_name = str(row.get("Player", row.iloc[0])).strip()
        rows.append({
            "game_id": game_slug,
            # player_id is NOT NULL in the DDL. Interim: use player_name as a
            # synthetic ID until the BR player-slug extraction (decision #3) is
            # implemented in a later slice. Reversible: a future UPDATE can swap
            # synthetic IDs for real NBA player_ids by joining on player_name.
            "player_id": player_name,
            "player_name": player_name,
            "team_id": None,
            "team_name": None,
            "team_abbr": team_abbr,
            "opponent_team_name": None,
            "game_date": game_date,
            "season": None,
            "game_type": None,
            "is_win": None,
            "is_home": is_home,
            "minutes_played": mp,
            "pts": _int(row.get("PTS")),
            "ast": _int(row.get("AST")),
            "reb": _int(row.get("TRB")),
            "oreb": _int(row.get("ORB")),
            "dreb": _int(row.get("DRB")),
            "stl": _int(row.get("STL")),
            "blk": _int(row.get("BLK")),
            "tov": _int(row.get("TOV")),
            "pf": _int(row.get("PF")),
            "fgm": _int(row.get("FG")),
            "fga": _int(row.get("FGA")),
            "fg_pct": None if is_dnp else _safe_float(row.get("FG%")),
            "fg3m": _int(row.get("3P")),
            "fg3a": _int(row.get("3PA")),
            "fg3_pct": None if is_dnp else _safe_float(row.get("3P%")),
            "ftm": _int(row.get("FT")),
            "fta": _int(row.get("FTA")),
            "ft_pct": None if is_dnp else _safe_float(row.get("FT%")),
            "plus_minus": None if is_dnp else _safe_float(row.get("+/-")),
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


def _extract_team_totals(df: pd.DataFrame) -> Optional[pd.Series]:
    """Return the 'Team Totals' row from a basic box DataFrame, or None.

    The Team Totals row contains team-level FG/FGA/3P/3PA/FT/FTA/REB/AST/STL/
    BLK/TOV/PF/PTS. _drop_totals_row removes this for player-grain flatteners;
    the game-grain flattener needs it instead.
    """
    if df is None or df.empty:
        return None
    df = _flatten_columns(df.copy())
    player_col = df.columns[0] if "Player" not in df.columns else "Player"
    mask = df[player_col].astype(str).str.contains("Team Totals", na=False)
    matches = df[mask]
    if matches.empty:
        return None
    return matches.iloc[0]


def _season_from_slug(game_slug: str) -> int:
    """Derive NBA season end-year from a slug's date.

    NBA seasons span Oct-Jun: Oct/Nov/Dec games of year Y are part of the
    Y+1 season; Jan-Jun games of year Y are part of the Y season.
    """
    year = int(game_slug[:4])
    month = int(game_slug[4:6])
    return year + 1 if month >= 10 else year


def flatten_game_row(
    game_slug: str,
    home_team: str,
    away_team: str,
    home_basic_df: pd.DataFrame,
    away_basic_df: pd.DataFrame,
    line_score_df: Optional[pd.DataFrame] = None,
) -> Optional[dict]:
    """Flatten a single game's team-level row for FLAT.games.

    Sources team stats from the "Team Totals" row of each team's basic box.
    If line_score is provided, prefers its total-points value over the basic
    box totals (they should match; line_score is more authoritative for the
    home/away score since it labels them explicitly).

    Args:
        game_slug: BR game slug (e.g., "20240409OMEM"). Used as game_id.
        home_team: Home team 3-letter abbr (from slug or table IDs).
        away_team: Away team 3-letter abbr (from table IDs).
        home_basic_df: Raw home team basic box DataFrame.
        away_basic_df: Raw away team basic box DataFrame.
        line_score_df: Optional hidden line_score DataFrame for score sanity.

    Returns:
        A single dict matching FLAT.games columns, or None if both totals rows
        are missing.
    """
    home_totals = _extract_team_totals(home_basic_df)
    away_totals = _extract_team_totals(away_basic_df)
    if home_totals is None or away_totals is None:
        logger.warning(
            "Missing team totals for %s (home=%s, away=%s)",
            game_slug, home_totals is not None, away_totals is not None,
        )
        return None

    game_date = f"{game_slug[:4]}-{game_slug[4:6]}-{game_slug[6:8]}"

    home_pts = _safe_int(home_totals.get("PTS"))
    away_pts = _safe_int(away_totals.get("PTS"))

    # Cross-check against line_score totals when available.
    if line_score_df is not None and not line_score_df.empty and len(line_score_df) >= 2:
        ls_flat = _flatten_columns(line_score_df.copy())
        # Row 0 = away, row 1 = home (BR convention).
        ls_home_t = _safe_int(ls_flat.iloc[1].get("T"))
        ls_away_t = _safe_int(ls_flat.iloc[0].get("T"))
        if ls_home_t is not None and home_pts is not None and ls_home_t != home_pts:
            logger.warning(
                "%s: home_pts disagree (line_score=%s, basic_totals=%s)",
                game_slug, ls_home_t, home_pts,
            )
        if ls_away_t is not None and away_pts is not None and ls_away_t != away_pts:
            logger.warning(
                "%s: away_pts disagree (line_score=%s, basic_totals=%s)",
                game_slug, ls_away_t, away_pts,
            )

    home_wl = (
        "W" if home_pts is not None and away_pts is not None and home_pts > away_pts
        else ("L" if home_pts is not None and away_pts is not None and home_pts < away_pts else None)
    )

    def _team_dict(prefix: str, totals: pd.Series) -> dict:
        return {
            f"{prefix}_fgm": _safe_int(totals.get("FG")),
            f"{prefix}_fga": _safe_int(totals.get("FGA")),
            f"{prefix}_fg_pct": _safe_float(totals.get("FG%")),
            f"{prefix}_fg3m": _safe_int(totals.get("3P")),
            f"{prefix}_fg3a": _safe_int(totals.get("3PA")),
            f"{prefix}_fg3_pct": _safe_float(totals.get("3P%")),
            f"{prefix}_ftm": _safe_int(totals.get("FT")),
            f"{prefix}_fta": _safe_int(totals.get("FTA")),
            f"{prefix}_ft_pct": _safe_float(totals.get("FT%")),
            f"{prefix}_oreb": _safe_int(totals.get("ORB")),
            f"{prefix}_dreb": _safe_int(totals.get("DRB")),
            f"{prefix}_reb": _safe_int(totals.get("TRB")),
            f"{prefix}_ast": _safe_int(totals.get("AST")),
            f"{prefix}_stl": _safe_int(totals.get("STL")),
            f"{prefix}_blk": _safe_int(totals.get("BLK")),
            f"{prefix}_tov": _safe_int(totals.get("TOV")),
            f"{prefix}_pf": _safe_int(totals.get("PF")),
            f"{prefix}_plus_minus": None,  # always 0 in totals row; leave NULL
        }

    row = {
        "game_id": game_slug,
        "game_date": game_date,
        "season": _season_from_slug(game_slug),
        "season_id": None,        # NBA Stats API format; not derivable from BR alone
        "season_type": None,      # Slice G can fill from schedule page
        "home_team_id": None,     # NBA Stats API team ID; not on BR
        "home_team_abbr": home_team,
        "away_team_id": None,
        "away_team_abbr": away_team,
        "home_pts": home_pts,
        "away_pts": away_pts,
        "home_wl": home_wl,
        "source": "br_scrape",
        "fetched_at": _now_utc(),
    }
    row.update(_team_dict("home", home_totals))
    row.update(_team_dict("away", away_totals))
    return row
