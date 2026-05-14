"""Fetch the list of game slugs for a given date from Basketball-Reference.

URL: https://www.basketball-reference.com/boxscores/?month=M&day=D&year=Y

Returns game slugs like "20231025ODAL" — the identifier used as the path
segment in box score URLs: /boxscores/20231025ODAL.html.
"""

from __future__ import annotations

import logging
from datetime import date

from nba_ingest.br_client import BASE_URL, extract_game_slugs_from_html, fetch

logger = logging.getLogger(__name__)


def list_games_on_date(game_date: date) -> list[str]:
    """Return BR game slugs for all games played on a given date.

    Fetches the daily boxscores index page and extracts game slug strings.
    Returns an empty list if no games were played (off-day, off-season).

    Args:
        game_date: The date to query.

    Returns:
        List of game slug strings, e.g. ["20231025ODAL", "20231025OLAL"].
        Empty list if no games on this date.
    """
    url = (
        f"{BASE_URL}/boxscores/"
        f"?month={game_date.month}&day={game_date.day}&year={game_date.year}"
    )
    logger.info("Fetching game list for %s from %s", game_date, url)

    html = fetch(url)
    slugs = extract_game_slugs_from_html(html)

    logger.info("Found %d game(s) on %s", len(slugs), game_date)
    return slugs
