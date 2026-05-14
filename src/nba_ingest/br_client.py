"""Basketball-Reference HTTP client.

Handles all HTTP communication with Basketball-Reference.com:
- Polite crawling: 3-second delay after every request (per robots.txt)
- Exponential backoff on 429/503 (BR occasionally rate-limits scrapers)
- Comment-extraction for tables hidden inside HTML comments (line_score, four_factors)

Usage:
    html = fetch("https://www.basketball-reference.com/boxscores/20231025ODAL.html")
    visible, hidden = parse_tables_with_comments(html)
    df = df_for("line_score", hidden)
"""

from __future__ import annotations

import logging
import re
import time
from typing import Optional

import pandas as pd
import requests
from bs4 import BeautifulSoup, Comment

logger = logging.getLogger(__name__)

# NOTE: Using a real Mac Safari UA avoids BR's bot-detection heuristics.
# Do not change this without testing that BR still returns full HTML content.
UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/17.4.1 Safari/605.1.15"
)

HEADERS = {
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.5",
}

# Crawl-delay from robots.txt. Never send requests faster than this.
CRAWL_DELAY_SEC = 3.0

BASE_URL = "https://www.basketball-reference.com"


def fetch(url: str) -> str:
    """GET a Basketball-Reference URL, enforce crawl-delay, return HTML text.

    Raises on non-200 after exhausting retries. Sleeps CRAWL_DELAY_SEC after
    every successful response (even on the last retry before raising).

    Args:
        url: Full URL to fetch.

    Returns:
        Response body as a string.

    Raises:
        requests.HTTPError: On non-200 after retries.
        requests.RequestException: On network failure.
    """
    backoff_sec = 30.0
    max_retries = 3

    for attempt in range(max_retries):
        logger.debug("GET %s (attempt %d/%d)", url, attempt + 1, max_retries)
        response = requests.get(url, headers=HEADERS, timeout=30)

        if response.status_code in (429, 503):
            # BR is rate-limiting us. Back off and retry.
            logger.warning(
                "HTTP %d from BR — backing off %.0fs (attempt %d/%d)",
                response.status_code,
                backoff_sec,
                attempt + 1,
                max_retries,
            )
            time.sleep(backoff_sec)
            backoff_sec *= 2
            continue

        # Always sleep the crawl-delay before returning, even on success.
        time.sleep(CRAWL_DELAY_SEC)

        if response.status_code != 200:
            logger.error("HTTP %d for %s", response.status_code, url)
            response.raise_for_status()

        return response.text

    # Exhausted retries on 429/503.
    raise requests.HTTPError(f"Exhausted {max_retries} retries on {url} due to rate limiting")


def parse_tables_with_comments(html: str) -> tuple[dict[str, pd.DataFrame], dict[str, pd.DataFrame]]:
    """Parse a BR page and return visible and comment-hidden tables.

    BR hides some tables (line_score, four_factors) inside HTML comments.
    Standard BS4 parsing won't find them — we extract comment nodes first
    and parse them separately.

    Args:
        html: Raw HTML string from a BR page.

    Returns:
        Tuple of (visible_tables, hidden_tables), both dicts keyed by table id.
        Values are DataFrames parsed from <table> elements.
    """
    soup = BeautifulSoup(html, "html5lib")

    visible = _extract_tables_from_soup(soup)

    # Pull tables out of HTML comment nodes.
    hidden: dict[str, pd.DataFrame] = {}
    for comment in soup.find_all(string=lambda text: isinstance(text, Comment)):
        comment_soup = BeautifulSoup(str(comment), "html5lib")
        hidden.update(_extract_tables_from_soup(comment_soup))

    return visible, hidden


def _extract_tables_from_soup(soup: BeautifulSoup) -> dict[str, pd.DataFrame]:
    """Pull all <table id="..."> elements from a soup and return as DataFrames."""
    tables: dict[str, pd.DataFrame] = {}
    for table in soup.find_all("table", id=True):
        table_id = table["id"]
        try:
            # BR tables typically have thead/tbody; read_html handles multi-level headers.
            dfs = pd.read_html(str(table))
            if dfs:
                tables[table_id] = dfs[0]
        except Exception:
            logger.debug("Could not parse table id=%s", table_id)
    return tables


def df_for(table_id: str, all_tables: dict[str, pd.DataFrame]) -> Optional[pd.DataFrame]:
    """Return the DataFrame for a given table_id, or None if not found.

    Args:
        table_id: The HTML table's id attribute.
        all_tables: Dict returned by parse_tables_with_comments (visible or hidden).

    Returns:
        DataFrame or None.
    """
    return all_tables.get(table_id)


def extract_game_slugs_from_html(html: str) -> list[str]:
    """Parse the daily boxscores index page and return game slugs.

    URL: /boxscores/?month=M&day=D&year=Y
    Slug format: YYYYMMDD0HOME (e.g., 20231025ODAL)

    Args:
        html: HTML from the daily index page.

    Returns:
        List of game slug strings (no duplicates, in page order).
    """
    slugs = re.findall(r"/boxscores/(\d{8}0[A-Z]{3})\.html", html)
    # Deduplicate while preserving order (each game link typically appears twice).
    seen: set[str] = set()
    unique: list[str] = []
    for slug in slugs:
        if slug not in seen:
            seen.add(slug)
            unique.append(slug)
    return unique
