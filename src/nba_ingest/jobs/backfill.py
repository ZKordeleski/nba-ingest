"""Backfill job: scrape and ingest all games for a historical season.

Wraps Slice G's settle_date(d) by enumerating every date that had games in a
target season (parsed from BR's monthly schedule pages), then settling each
date. The MERGE pattern means already-settled rows are idempotently updated;
interrupting and resuming a backfill is safe.

Modes (selected by env var):

    BACKFILL_SEASON=2023-24
        Backfill an entire NBA season. Iterates Oct-Jun monthly schedule
        pages, collects unique game dates, settles each one.
        Wall time: ~4.5 hours for a 1,230-game regular season (BR's 3s
        crawl-delay × 4 fetches/game × 1230 games).

    BACKFILL_DATES=2024-04-09,2024-04-11
        Backfill a specific date range (inclusive on both ends). Useful for
        testing or filling small gaps without re-fetching a whole season.

Per-date failures log and continue — one bad date doesn't halt the rest.
Aggregate counters are reported at the end.
"""

from __future__ import annotations

import logging
import os
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[3] / ".env", override=False)

from nba_ingest.fetchers.schedule import SEASON_MONTHS, fetch_schedule_month
from nba_ingest.flatteners.schedule import flatten_schedule
from nba_ingest.jobs.daily_settle import settle_date

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)


def _parse_season(season_str: str) -> tuple[int, int]:
    """Parse "2023-24" -> (2023, 2024). End year may be 2-digit."""
    parts = season_str.split("-")
    if len(parts) != 2:
        raise ValueError(f"Invalid season format: {season_str!r}. Expected 'YYYY-YY'.")
    start_year = int(parts[0])
    end_suffix = parts[1]
    if len(end_suffix) == 2:
        century = (start_year // 100) * 100
        end_year = century + int(end_suffix)
        if end_year < start_year:
            end_year += 100
    else:
        end_year = int(end_suffix)
    return start_year, end_year


def _collect_season_dates(end_year: int) -> list[date]:
    """Enumerate all dates with played games in a BR season via monthly schedules."""
    game_dates: set[date] = set()

    for month in SEASON_MONTHS:
        df = fetch_schedule_month(end_year, month)
        if df is None:
            continue
        rows = flatten_schedule(end_year, df)
        for row in rows:
            if not row.get("has_score"):
                continue  # Future game; not yet played
            try:
                game_date = datetime.strptime(row["game_date"], "%Y-%m-%d").date()
                game_dates.add(game_date)
            except (ValueError, TypeError):
                logger.warning("Could not parse date: %r", row.get("game_date"))

    return sorted(game_dates)


def _parse_date_range(range_str: str) -> list[date]:
    """Parse "YYYY-MM-DD,YYYY-MM-DD" → list of dates from start to end inclusive."""
    parts = [p.strip() for p in range_str.split(",")]
    if len(parts) != 2:
        raise ValueError(
            f"Invalid range: {range_str!r}. Expected 'YYYY-MM-DD,YYYY-MM-DD'."
        )
    start = datetime.strptime(parts[0], "%Y-%m-%d").date()
    end = datetime.strptime(parts[1], "%Y-%m-%d").date()
    if end < start:
        raise ValueError(f"end ({end}) precedes start ({start})")
    days = (end - start).days
    return [start + timedelta(days=i) for i in range(days + 1)]


def backfill_dates(dates: list[date]) -> dict:
    """Run settle_date for each given date; aggregate counters across all dates."""
    totals = {
        "dates_with_games": 0, "dates_empty": 0, "dates_failed": 0,
        "games_settled": 0, "games_failed": 0,
        "games_inserted": 0, "games_updated": 0,
        "player_box_inserted": 0, "player_box_updated": 0,
        "player_box_advanced_inserted": 0, "player_box_advanced_updated": 0,
        "line_scores_inserted": 0, "line_scores_updated": 0,
        "player_count": 0, "advanced_count": 0,
    }

    for i, d in enumerate(dates, 1):
        logger.info("=== [%d/%d] Settling %s ===", i, len(dates), d)
        try:
            result = settle_date(d)
            if result["games_found"] == 0:
                totals["dates_empty"] += 1
            else:
                totals["dates_with_games"] += 1
                totals["games_settled"] += result["games_settled"]
                totals["games_failed"] += result["games_failed"]
                for k, v in result.get("totals", {}).items():
                    totals[k] += v
        except Exception as e:
            logger.error("settle_date(%s) raised: %s", d, e)
            totals["dates_failed"] += 1

    logger.info(
        "Backfill complete: %d dates with games, %d empty, %d failed; "
        "%d games settled (games +%d/~%d, basic +%d/~%d, advanced +%d/~%d, line +%d/~%d)",
        totals["dates_with_games"], totals["dates_empty"], totals["dates_failed"],
        totals["games_settled"],
        totals["games_inserted"], totals["games_updated"],
        totals["player_box_inserted"], totals["player_box_updated"],
        totals["player_box_advanced_inserted"], totals["player_box_advanced_updated"],
        totals["line_scores_inserted"], totals["line_scores_updated"],
    )
    return totals


def main() -> None:
    season_str = os.environ.get("BACKFILL_SEASON", "").strip()
    range_str = os.environ.get("BACKFILL_DATES", "").strip()

    if not season_str and not range_str:
        logger.error(
            "Set BACKFILL_SEASON=2023-24 (full season) "
            "or BACKFILL_DATES=YYYY-MM-DD,YYYY-MM-DD (range)."
        )
        sys.exit(1)

    if range_str:
        dates = _parse_date_range(range_str)
        logger.info("Backfilling date range %s (%d days)", range_str, len(dates))
    else:
        _, end_year = _parse_season(season_str)
        logger.info("Backfilling season %s (BR end year: %d)", season_str, end_year)
        dates = _collect_season_dates(end_year)
        if not dates:
            logger.error("No game dates found for season %s. Check schedule pages.", season_str)
            sys.exit(1)
        logger.info("Season %s: %d game dates (%s to %s)",
                    season_str, len(dates), dates[0], dates[-1])

    backfill_dates(dates)


if __name__ == "__main__":
    main()
