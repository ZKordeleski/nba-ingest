"""Fetch monthly NBA schedule pages from Basketball-Reference.

URL: https://www.basketball-reference.com/leagues/NBA_{year}_games-{month}.html

Example: /leagues/NBA_2024_games-october.html (2023-24 regular season, October)

The schedule table (id="schedule") lists all games for that month including
date, teams, scores, and a link to the box score.

Note: BR uses the season end year in the URL (2024 = 2023-24 season).
"""

from __future__ import annotations

import logging

import pandas as pd

from nba_ingest.br_client import BASE_URL, df_for, fetch, parse_tables_with_comments

logger = logging.getLogger(__name__)

# NOTE: Month names as they appear in BR schedule URLs (lowercase, full name).
SEASON_MONTHS = [
    "october",
    "november",
    "december",
    "january",
    "february",
    "march",
    "april",
    "may",    # playoffs
    "june",   # playoffs/finals
]


def fetch_schedule_month(year: int, month: str) -> pd.DataFrame | None:
    """Fetch the schedule table for one month of an NBA season.

    Args:
        year: BR season end year (e.g., 2024 for the 2023-24 season).
        month: Lowercase full month name (e.g., "october", "november").

    Returns:
        DataFrame of schedule rows, or None if the page doesn't exist
        (e.g., a June page in a year where playoffs ended in May).
    """
    url = f"{BASE_URL}/leagues/NBA_{year}_games-{month}.html"
    logger.info("Fetching schedule: %s", url)

    try:
        html = fetch(url)
    except Exception as e:
        logger.warning("Could not fetch schedule page %s: %s", url, e)
        return None

    visible, _ = parse_tables_with_comments(html)
    df = df_for("schedule", visible)

    if df is None:
        logger.warning("No schedule table found at %s", url)
        return None

    logger.info("Got %d schedule rows for %s %s", len(df), month, year)
    return df
