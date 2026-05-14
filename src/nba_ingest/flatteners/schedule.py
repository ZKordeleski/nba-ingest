"""Flatten Basketball-Reference schedule DataFrames into FLAT schema dicts.

Schedule pages (/leagues/NBA_{year}_games-{month}.html) return a table with
columns like: Date, Start (ET), Visitor/Neutral, PTS, Home/Neutral, PTS, ...

These are used by the backfill job to enumerate which dates had games, so we
know which box score pages to fetch. The schedule table itself isn't stored in
FLAT — game data comes from the individual box score pages.
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Optional

import pandas as pd

logger = logging.getLogger(__name__)


def flatten_schedule(year: int, df: pd.DataFrame) -> list[dict]:
    """Map a schedule DataFrame to a list of game-date dicts.

    Returns a minimal representation: just date, home_team, away_team, and
    whether the game has a box score link yet (i.e., was already played).

    Args:
        year: BR season end year.
        df: Raw DataFrame from the schedule table.

    Returns:
        List of dicts with keys: game_date, home_team, away_team, has_score.
    """
    if df is None or df.empty:
        return []

    rows = []
    for _, row in df.iterrows():
        # Skip header rows that repeat inside the table body.
        date_val = str(row.iloc[0]) if not pd.isna(row.iloc[0]) else ""
        if date_val in ("", "Date", "Playoffs"):
            continue

        # Check if this game has been played (score columns are non-empty).
        pts_cols = [c for c in df.columns if "PTS" in str(c).upper()]
        has_score = len(pts_cols) > 0 and not pd.isna(row[pts_cols[0]])

        # Extract team names — column positions vary; use string search.
        visitor_col = next((c for c in df.columns if "Visitor" in str(c)), df.columns[2] if len(df.columns) > 2 else None)
        home_col = next((c for c in df.columns if "Home" in str(c)), df.columns[4] if len(df.columns) > 4 else None)

        # Parse BR date string "Mon, Apr 1, 2024" → ISO "2024-04-01"
        try:
            game_date = datetime.strptime(date_val, "%a, %b %d, %Y").strftime("%Y-%m-%d")
        except ValueError:
            logger.warning("Could not parse date: %r — skipping row", date_val)
            continue

        rows.append({
            "season_year": year,
            "game_date": game_date,
            "away_team": str(row[visitor_col]).strip() if visitor_col else None,
            "home_team": str(row[home_col]).strip() if home_col else None,
            "has_score": has_score,
        })

    return rows
