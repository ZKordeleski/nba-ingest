"""Backfill job: scrape and ingest all games for a historical season.

Designed to be run locally one season at a time. Fetches the monthly schedule
to enumerate which dates had games, then calls the settle logic for each date.

Usage:
    BACKFILL_SEASON=2023-24 python -m nba_ingest.jobs.backfill
    BACKFILL_SEASON=2024-25 python -m nba_ingest.jobs.backfill

Season format: "{start_year}-{end_year_2digit}" (e.g., "2023-24").

A full regular season (~1,230 games) takes roughly 25-30 minutes at the
3-second crawl-delay. Playoffs add ~20 minutes.

The job is idempotent: if a game is already in FLAT, the MERGE on the natural
key (game_id, player_id) leaves the existing row unchanged.

Progress is logged per date so you can interrupt and resume. Already-settled
dates don't get re-scraped (the MERGE is a no-op if the row exists).
"""

from __future__ import annotations

import logging
import os
import sys
from datetime import date, datetime

from nba_ingest.fetchers.games import list_games_on_date
from nba_ingest.fetchers.schedule import SEASON_MONTHS, fetch_schedule_month
from nba_ingest.flatteners.schedule import flatten_schedule

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)


def _parse_season(season_str: str) -> tuple[int, int]:
    """Parse "2023-24" -> (2023, 2024).

    Args:
        season_str: Season in format "YYYY-YY" (e.g., "2023-24").

    Returns:
        Tuple of (start_year, end_year).
    """
    parts = season_str.split("-")
    if len(parts) != 2:
        raise ValueError(f"Invalid season format: {season_str!r}. Expected 'YYYY-YY'.")
    start_year = int(parts[0])
    # The end year suffix may be 2-digit (24) — reconstruct full year.
    end_suffix = parts[1]
    if len(end_suffix) == 2:
        century = (start_year // 100) * 100
        end_year = century + int(end_suffix)
        if end_year < start_year:
            end_year += 100
    else:
        end_year = int(end_suffix)
    return start_year, end_year


def _collect_game_dates(end_year: int) -> list[date]:
    """Enumerate all dates with games in a season by parsing monthly schedules.

    Args:
        end_year: BR season end year (e.g., 2024 for 2023-24 season).

    Returns:
        Sorted list of dates that have games, in chronological order.
    """
    game_dates: set[date] = set()

    for month in SEASON_MONTHS:
        df = fetch_schedule_month(end_year, month)
        if df is None:
            continue

        rows = flatten_schedule(end_year, df)
        for row in rows:
            if not row.get("has_score"):
                continue  # Game hasn't been played yet
            try:
                game_date = datetime.strptime(row["game_date"], "%a, %b %d, %Y").date()
                game_dates.add(game_date)
            except (ValueError, TypeError):
                logger.debug("Could not parse date: %r", row.get("game_date"))

    sorted_dates = sorted(game_dates)
    logger.info("Found %d game dates in season %d", len(sorted_dates), end_year)
    return sorted_dates


def main() -> None:
    season_str = os.environ.get("BACKFILL_SEASON", "").strip()
    if not season_str:
        logger.error("BACKFILL_SEASON env var is required. Example: BACKFILL_SEASON=2023-24")
        sys.exit(1)

    start_year, end_year = _parse_season(season_str)
    logger.info("Backfilling season %d-%d (BR year: %d)", start_year, end_year, end_year)

    game_dates = _collect_game_dates(end_year)

    if not game_dates:
        logger.error("No game dates found for season %d. Check schedule pages.", end_year)
        sys.exit(1)

    logger.info(
        "Season %s: %d dates to settle (%s to %s)",
        season_str,
        len(game_dates),
        game_dates[0],
        game_dates[-1],
    )

    # Import here to avoid circular deps at module level.
    from nba_ingest.jobs.daily_settle import main as settle_one_date

    settled = 0
    skipped = 0

    for game_date in game_dates:
        # Override the SETTLE_DATE env var for each iteration.
        os.environ["SETTLE_DATE"] = game_date.isoformat()
        logger.info("--- Settling %s (%d/%d) ---", game_date, settled + skipped + 1, len(game_dates))

        try:
            settle_one_date()
            settled += 1
        except SystemExit as e:
            # daily_settle calls sys.exit(0) on no-game days — treat as a skip.
            if e.code == 0:
                skipped += 1
                logger.info("No games on %s — skipped.", game_date)
            else:
                logger.error("Settle failed for %s with exit code %s", game_date, e.code)
        except Exception as e:
            logger.error("Settle failed for %s: %s", game_date, e)

    logger.info(
        "Backfill complete for season %s: %d dates settled, %d skipped.",
        season_str,
        settled,
        skipped,
    )


if __name__ == "__main__":
    main()
