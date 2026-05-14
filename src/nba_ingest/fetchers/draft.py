"""Fetch NBA draft class pages from Basketball-Reference.

URL: https://www.basketball-reference.com/draft/NBA_{year}.html

The draft page contains a table (id="stats") listing all picks for that draft
class including the team that drafted them, their college/organization, and
up-to-date career statistics. Career stats update in real-time as players play,
making this the source for the weekly_meta career stats refresh (Slice 5).

Note: Table ID is "stats", not "draft". Multi-level column headers (same
flattening approach as box scores applies here).
"""

from __future__ import annotations

import logging

import pandas as pd

from nba_ingest.br_client import BASE_URL, df_for, fetch, parse_tables_with_comments

logger = logging.getLogger(__name__)


def fetch_draft_class(year: int) -> pd.DataFrame | None:
    """Fetch the draft class table for a given year.

    Args:
        year: The draft year (e.g., 2023).

    Returns:
        DataFrame of draft pick rows with career stats, or None on failure.
    """
    url = f"{BASE_URL}/draft/NBA_{year}.html"
    logger.info("Fetching draft class: %s", url)

    try:
        html = fetch(url)
    except Exception as e:
        logger.warning("Could not fetch draft page %s: %s", url, e)
        return None

    visible, _ = parse_tables_with_comments(html)
    df = df_for("stats", visible)

    if df is None:
        logger.warning("No 'stats' table found on draft page %s", url)
        return None

    logger.info("Got %d draft picks for class of %d", len(df), year)
    return df
