"""Phase 2 slice orchestrator: all 30 teams, 2024-25 -> ZK_NBA_V2.

Generalizes Phase 1 to the full season via the shared src/nba_ingest/v2/slice.py.
Walks every team's season page, dedupes shared games (each game appears on two
team pages), and CHECKPOINTS by skipping game_ids already loaded — so a re-run
(or an interrupted background run) resumes instead of restarting. Loads in
committed batches. Quarantine-not-poison preserved.

Usage:
    .venv/bin/python dev/_phase2_slice.py --teams DEN,OKC,IND   # smoke subset
    .venv/bin/python dev/_phase2_slice.py                       # all 30 teams
    .venv/bin/python dev/_phase2_slice.py --reset               # wipe + full reload
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

from nba_ingest.br_client import BASE_URL, extract_game_slugs_from_html, fetch
from nba_ingest.snowflake_client import connect
from nba_ingest.v2 import slice as v2

logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(message)s")
log = logging.getLogger("phase2")
log.setLevel(logging.INFO)

SEASON = 2025
TABLES = ["games", "player_box_basic", "player_box_advanced", "line_scores",
          "game_officials", "game_inactives"]
BATCH = 40  # games per committed batch (checkpoint granularity)


def enumerate_all_games(teams) -> list[str]:
    seen, out = set(), []
    for i, abbr in enumerate(teams, 1):
        html = fetch(f"{BASE_URL}/teams/{abbr}/{SEASON}_games.html")
        n_new = 0
        for slug in extract_game_slugs_from_html(html):
            if slug not in seen:
                seen.add(slug)
                out.append(slug)
                n_new += 1
        log.info("[%d/%d] %s: +%d new (total %d)", i, len(teams), abbr, n_new, len(out))
    return out


def load_batch(conn, buckets):
    cur = conn.cursor()
    try:
        total = sum(v2.insert(cur, t, buckets[t]) for t in TABLES)
        conn.commit()
        return total
    finally:
        cur.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--teams", default="", help="comma-separated BR abbrs (default: all 30)")
    ap.add_argument("--limit", type=int, default=0, help="cap games (smoke test)")
    ap.add_argument("--reset", action="store_true", help="wipe game tables before loading")
    args = ap.parse_args()

    teams = args.teams.split(",") if args.teams else list(v2.TEAM_NICKNAMES.keys())
    conn = connect()
    try:
        cur = conn.cursor()
        if args.reset:
            for t in TABLES + ["playoff_series", "quarantine"]:
                cur.execute(f"DELETE FROM ZK_NBA_V2.FLAT.{t}")
            conn.commit()
        cur.execute("CREATE TABLE IF NOT EXISTS ZK_NBA_V2.FLAT.quarantine "
                    "(game_id STRING, reason STRING, fetched_at TIMESTAMP_NTZ)")
        # checkpoint: which games are already loaded?
        cur.execute("SELECT game_id FROM ZK_NBA_V2.FLAT.games")
        done = {r[0] for r in cur.fetchall()}
        cur.execute("SELECT game_id FROM ZK_NBA_V2.FLAT.quarantine")
        done |= {r[0] for r in cur.fetchall()}
        cur.close()
        log.info("checkpoint: %d games already processed", len(done))

        # playoff bracket (refresh each run — small)
        series = v2.fetch_playoff_series(SEASON)
        cur = conn.cursor()
        cur.execute("DELETE FROM ZK_NBA_V2.FLAT.playoff_series")
        v2.insert(cur, "playoff_series", series, v2.SERIES_COLS)
        conn.commit(); cur.close()
        log.info("playoff_series: %d rows (rounds: %s)", len(series),
                 sorted({s["round"] for s in series if s["round"]}))

        log.info("enumerating games for %d teams…", len(teams))
        slugs = [s for s in enumerate_all_games(teams) if s not in done]
        if args.limit:
            slugs = slugs[: args.limit]
        log.info("%d games to process (after checkpoint skip)", len(slugs))

        buckets = {t: [] for t in TABLES}
        n_ok = n_q = pending = 0
        quarantined = []
        for i, slug in enumerate(slugs, 1):
            try:
                res = v2.build_game(slug, SEASON, series)
            except Exception as exc:  # noqa: BLE001
                res = ("quarantine", f"error: {exc!r}")
            if isinstance(res, tuple):  # quarantined
                quarantined.append((slug, res[1])); n_q += 1
                log.warning("[%d/%d] %s QUARANTINED: %s", i, len(slugs), slug, res[1])
                continue
            for t in TABLES:
                buckets[t].extend(res[t])
            n_ok += 1; pending += 1
            if i % 25 == 0:
                log.info("[%d/%d] ok=%d q=%d", i, len(slugs), n_ok, n_q)
            if pending >= BATCH:
                load_batch(conn, buckets)
                buckets = {t: [] for t in TABLES}; pending = 0
        if pending:
            load_batch(conn, buckets)
        if quarantined:
            cur = conn.cursor()
            now = v2._now_utc()
            cur.executemany("INSERT INTO ZK_NBA_V2.FLAT.quarantine VALUES (%s,%s,%s)",
                            [(g, r, now) for g, r in quarantined])
            conn.commit(); cur.close()
    finally:
        conn.close()

    print(f"\nDONE. loaded={n_ok} quarantined={n_q}")
    for g, r in quarantined[:20]:
        print(f"  Q {g}: {r}")


if __name__ == "__main__":
    sys.exit(main())
