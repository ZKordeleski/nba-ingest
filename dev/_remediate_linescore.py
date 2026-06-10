"""Gate remediation — quarantine already-admitted games whose caveat now EXCEEDS
its ceiling.

Before the symmetric-ceiling fix, line_score_discrepancy had no upper bound, so
bug-sized gaps (incomplete quarter parse in old BAA box scores; final score still
correct) were admitted as mere caveats. Zack's call: quarantine them for human
review — re-admit responsibly later if the source data supports it.

This finds those games, MOVES each to the rich quarantine worklist (reason_class
line_score_blocker, with the discrepancy detail in context for the reviewer), and
deletes its rows from every FLAT table. Idempotent: a game already gone from
`games` is skipped.

⚠️ RUN AT THE POST-BACKFILL GATE, after sql/v2/060_quarantine.sql (needs the rich
quarantine schema). Read-only preview first:
    .venv/bin/python dev/_remediate_linescore.py            # preview
    .venv/bin/python dev/_remediate_linescore.py --apply    # execute
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

from nba_ingest.snowflake_client import connect, execute
from nba_ingest.v2 import slice as v2

# caveat_type -> its current ceiling. A game whose caveat magnitude exceeds this is
# now bug-sized and must be quarantined rather than admitted.
CEILINGS = {
    "line_score_discrepancy": v2.CAVEAT_LINESCORE_MAX,
    "player_id_collision": v2.CAVEAT_COLLISION_MAX,
    "reconciliation_discrepancy": v2.CAVEAT_RECON_MAX,
}
FLAT_TABLES = ["player_box_basic", "player_box_advanced", "line_scores",
               "game_officials", "game_inactives", "data_caveats", "games"]
REASON_CLASS = {"line_score_discrepancy": "line_score_blocker"}  # else guard_blocker


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="execute (default: preview only)")
    args = ap.parse_args()

    conn = connect()
    try:
        # offenders: distinct game + worst caveat type/magnitude over its ceiling
        offenders = {}
        for ctype, ceil in CEILINGS.items():
            for gid, mag, season, detail in execute(conn, f"""
                SELECT c.game_id, c.magnitude, g.season,
                       LISTAGG(c.detail, ' | ') WITHIN GROUP (ORDER BY c.detail)
                FROM ZK_NBA_V2.FLAT.data_caveats c
                JOIN ZK_NBA_V2.FLAT.games g USING (game_id)
                WHERE c.caveat_type = '{ctype}' AND c.magnitude > {ceil}
                GROUP BY c.game_id, c.magnitude, g.season"""):
                cur = offenders.get(gid)
                if cur is None or mag > cur["magnitude"]:
                    offenders[gid] = {"game_id": gid, "season": season, "ctype": ctype,
                                      "magnitude": mag, "detail": detail}

        if not offenders:
            print("No over-ceiling games to remediate. (clean)")
            return 0

        print(f"{len(offenders)} game(s) over ceiling -> quarantine:")
        for o in sorted(offenders.values(), key=lambda x: -x["magnitude"]):
            print(f"  {o['game_id']} ({o['season']}) {o['ctype']} mag={o['magnitude']}")
        if not args.apply:
            print("\nPREVIEW only. Re-run with --apply to execute.")
            return 0

        cur = conn.cursor()
        qrows = []
        for o in offenders.values():
            qrows.append(v2.quarantine_row(o["game_id"], o["season"],
                         REASON_CLASS.get(o["ctype"], "guard_blocker"), "guard",
                         f"re-evaluated over ceiling: {o['detail']}",
                         {"caveat_type": o["ctype"], "magnitude": o["magnitude"]}))
        ids = list(offenders.keys())
        ph = ",".join(["%s"] * len(ids))
        for t in FLAT_TABLES:
            cur.execute(f"DELETE FROM ZK_NBA_V2.FLAT.{t} WHERE game_id IN ({ph})", tuple(ids))
        v2.insert_quarantine(cur, qrows)
        conn.commit(); cur.close()
        print(f"\nApplied: {len(ids)} games moved to quarantine, removed from {len(FLAT_TABLES)} tables.")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
