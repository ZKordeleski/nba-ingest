"""V2 daily ingest — settle recent games into ZK_NBA_V2.

The daily ingest for ZK_NBA_V2 — and now the SOLE daily cron (it replaced the V1
`jobs/daily_settle.py`, since deleted, which carried the LEFT(game_id,1) season_type/
round bug). Enumerates games by DATE (handles any in-season day, including playoffs)
and loads them through the shared v2 spine, so every new game gets correct season_type/
round, the bad-data guard, NULL discipline, and NBA Cup Championship tagging. Checkpoint
skips already-loaded games, so re-running is a safe no-op.

This cron is now ACTIVE (v2_daily.yml, 2026-06-22) and the V1 daily_settle cron is
retired. The ZK_NBA_V2 -> ZK_NBA rename remains a separate, deliberate step; settling
into V2 before the rename is correct (the rename only swaps the name).

Usage:
    .venv/bin/python dev/_settle.py --days 2          # settle the last 2 days
    .venv/bin/python dev/_settle.py --date 2026-06-03 # settle one date
"""

from __future__ import annotations

import argparse
import logging
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

from nba_ingest.fetchers.games import list_games_on_date
from nba_ingest.snowflake_client import connect
from nba_ingest.v2 import slice as v2

logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(message)s")
log = logging.getLogger("settle")
log.setLevel(logging.INFO)

TABLES = ["games", "player_box_basic", "player_box_advanced", "line_scores",
          "game_officials", "game_inactives", "data_caveats"]


def season_of(d: date) -> int:
    """NBA season end-year for a date (Oct-Jun spans: Nov 2025 -> season 2026)."""
    return d.year + 1 if d.month >= 10 else d.year


def main():
    ap = argparse.ArgumentParser()
    # --days defaults to 2 so a BARE `python dev/_settle.py` does the sensible cron thing
    # (settle the last 2 days, catching late-posted box scores). The default lives HERE,
    # in the tool — orchestrators (v2_daily.yml) pass --days only to override, and never
    # have to supply it just to be well-formed. (A bare invocation used to error.)
    ap.add_argument("--days", type=int, default=2,
                    help="settle the last N days, incl. today (default 2)")
    ap.add_argument("--date", help="settle a single date YYYY-MM-DD (overrides --days)")
    args = ap.parse_args()

    if args.date:
        dates = [datetime.strptime(args.date, "%Y-%m-%d").date()]
    else:
        today = date.today()
        dates = [today - timedelta(days=i) for i in range(max(args.days, 0))]

    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute("SELECT game_id FROM ZK_NBA_V2.FLAT.games")
        done = {r[0] for r in cur.fetchall()}
        cur.close()

        # one bracket fetch per season touched (for playoff round tagging)
        series_by_season: dict[int, list] = {}
        n_ok = n_q = 0
        for d in sorted(dates):
            season = season_of(d)
            if season not in series_by_season:
                try:
                    series_by_season[season] = v2.fetch_playoff_series(season)
                except v2.PlayoffsPageMissing:
                    # in-progress season before playoffs start: a missing page is
                    # EXPECTED here, not an anomaly — proceed with no bracket.
                    series_by_season[season] = []
            slugs = [s for s in list_games_on_date(d) if s not in done]
            log.info("%s (season %d): %d new games", d, season, len(slugs))
            buckets = {t: [] for t in TABLES}
            quarantined = []
            for slug in slugs:
                try:
                    res = v2.build_game(slug, season, series_by_season[season])
                except Exception as exc:  # noqa: BLE001
                    res = ("quarantine", v2.quarantine_row(slug, season, "fetch_error", "fetch", repr(exc)))
                if isinstance(res, tuple):
                    quarantined.append(res[1]); n_q += 1
                    log.warning("%s QUARANTINED: %s", slug, res[1]["detail"])
                    continue
                for t in TABLES:
                    buckets[t].extend(res[t])
                done.add(slug); n_ok += 1
            cur = conn.cursor()
            for t in TABLES:
                v2.insert(cur, t, buckets[t])
            v2.drain_quarantine(cur, [r["game_id"] for r in buckets["games"]])
            if quarantined:
                v2.insert_quarantine(cur, quarantined)
            conn.commit(); cur.close()
        # NBA Cup Championship doesn't count toward regular-season stats — re-tag it
        # out of Regular Season for any settled season. Idempotent (safe mid-tournament:
        # tags only once the final, a single game on the latest Cup date, is loaded).
        cur = conn.cursor()
        for season in series_by_season:
            gid = v2.tag_cup_championship(cur, season)
            if gid:
                log.info("tagged NBA Cup Championship: %s (season %d)", gid, season)
        conn.commit(); cur.close()
    finally:
        conn.close()
    print(f"\nDONE. settled={n_ok} quarantined={n_q}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
