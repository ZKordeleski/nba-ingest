"""Reusable season loader -> ZK_NBA_V2. The Phase 3+ / backfill spine.

Enumerates a whole season via the league monthly schedule pages (works for any
era, defunct franchises included), then fetch->flatten->guard->load via the
shared v2 slice module. Checkpoints by skipping game_ids already loaded for the
season, commits in batches, and retries transient connection errors — so a long
historical run resumes instead of restarting.

Usage:
    .venv/bin/python dev/_load_season.py --season 1973 --limit 5   # smoke
    .venv/bin/python dev/_load_season.py --season 1973             # full season
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

from nba_ingest.snowflake_client import connect
from nba_ingest.v2 import slice as v2

logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(message)s")
log = logging.getLogger("load_season")
log.setLevel(logging.INFO)

TABLES = ["games", "player_box_basic", "player_box_advanced", "line_scores",
          "game_officials", "game_inactives", "data_caveats", "audit_findings"]
BATCH = 40


def load_batch(conn, buckets):
    cur = conn.cursor()
    try:
        for t in TABLES:
            v2.insert(cur, t, buckets[t])
        # drain: a game that loads successfully leaves the quarantine worklist
        v2.drain_quarantine(cur, [r["game_id"] for r in buckets["games"]])
        conn.commit()
    finally:
        cur.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--season", type=int, required=True, help="NBA season end-year (1973 = 1972-73)")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    season = args.season

    conn = connect()
    try:
        cur = conn.cursor()
        # quarantine table is the rich game-grain worklist (sql/v2/060_quarantine.sql,
        # applied at the post-backfill gate); no ad-hoc CREATE here.
        cur.execute("SELECT game_id FROM ZK_NBA_V2.FLAT.games WHERE season=%s", (season,))
        done = {r[0] for r in cur.fetchall()}
        cur.execute("SELECT game_id FROM ZK_NBA_V2.FLAT.quarantine")
        done |= {r[0] for r in cur.fetchall()}
        cur.close()
        log.info("season %d checkpoint: %d games already processed", season, len(done))

        series = v2.fetch_playoff_series(season)
        if series:
            cur = conn.cursor()
            cur.execute("DELETE FROM ZK_NBA_V2.FLAT.playoff_series WHERE season=%s", (season,))
            v2.insert(cur, "playoff_series", series, v2.SERIES_COLS)
            conn.commit(); cur.close()
        log.info("playoff_series for %d: %d rows", season, len(series))

        slugs = [s for s in v2.enumerate_season_by_schedule(season) if s not in done]
        if args.limit:
            slugs = slugs[: args.limit]
        log.info("%d games to process for %d", len(slugs), season)

        buckets = {t: [] for t in TABLES}
        n_ok = n_q = pending = 0
        quarantined = []
        for i, slug in enumerate(slugs, 1):
            try:
                res = v2.build_game(slug, season, series)
            except Exception as exc:  # noqa: BLE001
                res = ("quarantine", v2.quarantine_row(slug, season, "fetch_error", "fetch", repr(exc)))
            if isinstance(res, tuple):
                quarantined.append(res[1]); n_q += 1
                log.warning("[%d/%d] %s QUARANTINED: %s", i, len(slugs), slug, res[1]["detail"])
                continue
            for t in TABLES:
                buckets[t].extend(res[t])
            n_ok += 1; pending += 1
            if i % 50 == 0:
                log.info("[%d/%d] ok=%d q=%d", i, len(slugs), n_ok, n_q)
            if pending >= BATCH:
                load_batch(conn, buckets); buckets = {t: [] for t in TABLES}; pending = 0
        if pending:
            load_batch(conn, buckets)
        if quarantined:
            cur = conn.cursor()
            v2.insert_quarantine(cur, quarantined)
            conn.commit(); cur.close()
    finally:
        conn.close()

    print(f"\nDONE season={season}. loaded={n_ok} quarantined={n_q}")
    for row in quarantined[:20]:
        print(f"  Q {row['game_id']}: {row['detail']}")


if __name__ == "__main__":
    sys.exit(main())
