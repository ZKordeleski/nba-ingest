"""Fetch and parse a single game's box score page from Basketball-Reference.

URL: https://www.basketball-reference.com/boxscores/{slug}.html

A box score page contains:
- Two visible basic box tables: box-{HOME}-game-basic, box-{AWAY}-game-basic
- Two visible advanced box tables: box-{HOME}-game-advanced, box-{AWAY}-game-advanced
- Two hidden comment tables: line_score, four_factors
- Page metadata (officials, inactives, attendance) in prose <div> elements

Slug format: YYYYMMDD0HOME (e.g., 20231025ODAL — Oct 25, 2023, Dallas home game)
"""

from __future__ import annotations

import logging
import re
from typing import Optional

import pandas as pd

from nba_ingest.br_client import BASE_URL, df_for, fetch, parse_tables_with_comments

logger = logging.getLogger(__name__)


def _team_abbrs_from_slug(game_slug: str) -> tuple[str, str]:
    """Extract home and away team abbreviations from a game slug.

    Slug format: YYYYMMDD0HOME (the last 3 chars are the home team).
    The away team must be inferred from the box table IDs found on the page.

    Returns:
        (home_abbr, away_abbr) — home is definitive from slug; away is best-guess
        returned as empty string here (caller determines from visible table IDs).
    """
    home = game_slug[-3:]
    return home, ""


def _find_team_abbrs_from_tables(game_slug: str, visible: dict[str, pd.DataFrame]) -> tuple[str, str]:
    """Find home and away team abbreviations from the visible table IDs.

    BR box table IDs follow the pattern: box-{TEAM}-game-basic. The home team
    is derived from the game slug (last 3 chars are always the home team code).
    BR lists the away team's box tables first in the HTML, so we cannot rely
    on insertion order to distinguish home from away.

    Args:
        game_slug: BR game slug (e.g., "20231025ODAL"). Last 3 chars = home team.
        visible: Dict of visible tables from parse_tables_with_comments.

    Returns:
        (home_abbr, away_abbr) — empty strings if not found.
    """
    home_from_slug = game_slug[-3:]
    teams: list[str] = []
    for table_id in visible:
        m = re.match(r"^box-([A-Z]{2,3})-game-basic$", table_id)
        if m:
            teams.append(m.group(1))

    if len(teams) == 2:
        if home_from_slug in teams:
            away = next(t for t in teams if t != home_from_slug)
            return home_from_slug, away
        # Slug home team not found in tables — log and fall back to order
        logger.warning(
            "Slug home team %s not found in box table IDs %s for %s",
            home_from_slug, teams, game_slug,
        )
        return teams[0], teams[1]
    return home_from_slug, ""


def _parse_meta(html: str) -> dict:
    """Extract officials, inactives, and attendance from page prose.

    These are not in tables — they're in <div> elements with inline text.
    Regex extraction is fragile; log warnings on failure rather than raising.

    Returns:
        Dict with keys: officials (list[str]), inactives (list[str]), attendance (int|None).
    """
    meta: dict = {"officials": [], "inactives": [], "attendance": None}

    # Attendance: "Attendance: 19,812"
    att_match = re.search(r"Attendance:\s*([\d,]+)", html)
    if att_match:
        try:
            meta["attendance"] = int(att_match.group(1).replace(",", ""))
        except ValueError:
            pass

    # Officials: a comma-separated list of linked names after "Officials:"
    # Extract all text anchors after the label.
    officials_section = re.search(r"Officials:.*?(<a[^>]+>[^<]+</a>.*?)(?:</div>|</p>)", html, re.DOTALL)
    if officials_section:
        meta["officials"] = re.findall(r">([^<]+)</a>", officials_section.group(1))

    # Inactive players: listed after team abbreviation labels
    # Pattern: "Inactive: Name, Name, Name"
    inactive_matches = re.findall(r"Inactive:\s*([^<\n]+)", html)
    for match in inactive_matches:
        names = [n.strip() for n in match.split(",") if n.strip()]
        meta["inactives"].extend(names)

    return meta


def fetch_boxscore(game_slug: str) -> dict:
    """Fetch and parse a BR box score page.

    Returns a dict with keys:
        game_slug: str
        home_team: str  (3-letter abbreviation)
        away_team: str  (3-letter abbreviation)
        basic: {home_team: DataFrame, away_team: DataFrame}
        advanced: {home_team: DataFrame, away_team: DataFrame}
        line_score: DataFrame (from hidden comment table)
        four_factors: DataFrame (from hidden comment table)
        meta: dict with officials, inactives, attendance

    Any table that is missing from the page will be None in the returned dict.

    Args:
        game_slug: BR game identifier, e.g. "20231025ODAL".

    Returns:
        Dict with parsed box score data.
    """
    url = f"{BASE_URL}/boxscores/{game_slug}.html"
    logger.info("Fetching box score: %s", url)

    html = fetch(url)
    visible, hidden = parse_tables_with_comments(html)

    # Determine team abbreviations. Home team is always the slug's last 3 chars.
    home_team, away_team = _find_team_abbrs_from_tables(game_slug, visible)
    if not home_team:
        logger.warning("Could not determine team abbrs for %s", game_slug)

    result: dict = {
        "game_slug": game_slug,
        "home_team": home_team,
        "away_team": away_team,
        "basic": {
            "home": df_for(f"box-{home_team}-game-basic", visible),
            "away": df_for(f"box-{away_team}-game-basic", visible) if away_team else None,
        },
        "advanced": {
            "home": df_for(f"box-{home_team}-game-advanced", visible),
            "away": df_for(f"box-{away_team}-game-advanced", visible) if away_team else None,
        },
        "line_score": df_for("line_score", hidden),
        "four_factors": df_for("four_factors", hidden),
        "meta": _parse_meta(html),
    }

    # Log which tables were found vs missing.
    for key in ("line_score", "four_factors"):
        if result[key] is None:
            logger.warning("Table '%s' not found in %s", key, game_slug)

    return result
