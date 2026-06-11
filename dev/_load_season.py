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
          "game_officials", "game_inactives", "data_caveats"]
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
    ap.add_argument("--approve-no-playoffs", action="store_true",
                    help="human-reviewed override: load a season that has no BR playoffs page "
                         "(e.g. BAA 1947-49). Without this, such a season is BLOCKED for review.")
    ap.add_argument("--reviewer", help="who is approving (required with --approve-no-playoffs)")
    ap.add_argument("--note", help="why it's admitted without a bracket (required with --approve-no-playoffs)")
    args = ap.parse_args()
    if args.approve_no_playoffs and not (args.reviewer and args.note):
        ap.error("--approve-no-playoffs requires --reviewer and --note (the approval must be traceable)")
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

        # A missing playoffs page is a season-level ANOMALY. We never silently admit
        # an anomalous season: block it and flag it for human review. Re-running with
        # --approve-no-playoffs is the per-instance, human-in-the-loop approval — it
        # does NOT loosen the guard for any other season (guards don't auto-loosen).
        try:
            series = v2.fetch_playoff_series(season)
        except v2.PlayoffsPageMissing:
            if not args.approve_no_playoffs:
                cur = conn.cursor()
                v2.record_finding(cur, "missing_playoffs_page", "season", season,
                    f"season {season} has no /playoffs/NBA_{season}.html (BR's playoff pages "
                    f"begin at 1950; BAA 1947-49 have none). REVIEW before admitting the season; "
                    f"re-run dev/_load_season.py --season {season} --approve-no-playoffs once confirmed.",
                    severity="warn")
                conn.commit(); cur.close()
                log.error("BLOCKED season %d: missing playoffs page — flagged for review in "
                          "audit_findings. Nothing loaded. Re-run with --approve-no-playoffs "
                          "after review.", season)
                return 2  # distinct from a transient failure: needs human review, not a retry
            series = []
            cur = conn.cursor()
            v2.record_finding(cur, "missing_playoffs_page", "season", season,
                f"season {season}: no BR playoffs page — admitted without a bracket after human review.",
                severity="info", status="approved", note=f"{args.reviewer}: {args.note}")
            conn.commit(); cur.close()
            log.warning("APPROVED by %s: loading season %d without a bracket — %s",
                        args.reviewer, season, args.note)
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
