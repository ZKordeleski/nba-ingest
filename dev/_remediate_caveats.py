"""Gate remediation — re-quarantine EVERY game currently admitted-on-caveat.

TELOS (kept, not deleted): this is the **all-or-nothing reset** — it re-quarantines
*every* caveated game (no filter) so the entire caveat set is re-adjudicated from
scratch through dev/_approve.py. Use it ONLY when you want a clean-slate re-gate:
a from-zero rebuild, or a loss of confidence in the whole caveat ledger.

It is NOT the tool for a mixed state where some caveats are already properly signed —
running it then would WIPE good provenance and force re-approving work already done.
For backfilling provenance onto only the unsigned legacy caveats while preserving the
signed ones, use the surgical dev/_remediate_provenance.py instead (that is what ran
at the 2026-06-17 gate; this script was deliberately NOT used there).

(Durable counterpart for one-off approvals: dev/_approve.py — the permanent
human-approval path.)

Before the strict-guardrail fix, build_game auto-admitted flagged games with a
data_caveats row. Zack's call: those games subverted the guardrail and must go
through review like any other flag. This moves every currently-caveated game to the
quarantine worklist (with its caveats preserved in `context` for the reviewer) and
deletes its rows from every FLAT table, including data_caveats. A human then
re-admits the legitimate ones with dev/_approve.py (which re-writes the caveats).

After this runs, data_caveats is EMPTY until approvals repopulate it — exactly the
invariant we want: a caveat only ever means "a human approved this known imperfection".

⚠️ RUN AT THE POST-BACKFILL GATE, after sql/v2/060_quarantine.sql (needs the rich
quarantine schema). Preview first:
    dev/_remediate_caveats.py            # preview
    dev/_remediate_caveats.py --apply    # execute
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

from nba_ingest.snowflake_client import connect, execute
from nba_ingest.v2 import slice as v2

# a caveat is "hard" (bug-sized -> reason_class guard_blocker) if it exceeds its
# ceiling; else it is a soft discrepancy (data_discrepancy). Triage hint only.
CEILINGS = {"line_score_discrepancy": v2.CAVEAT_LINESCORE_MAX,
            "player_id_collision": v2.CAVEAT_COLLISION_MAX,
            "reconciliation_discrepancy": v2.CAVEAT_RECON_MAX}
FLAT_TABLES = ["player_box_basic", "player_box_advanced", "line_scores",
               "game_officials", "game_inactives", "data_caveats", "games"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="execute (default: preview only)")
    args = ap.parse_args()

    conn = connect()
    try:
        rows = execute(conn, """
            SELECT c.game_id, g.season, c.caveat_type, c.detail, c.magnitude
            FROM ZK_NBA_V2.FLAT.data_caveats c
            JOIN ZK_NBA_V2.FLAT.games g USING (game_id)
            ORDER BY c.game_id""")
        if not rows:
            print("No caveated games to remediate. (clean)"); return 0

        games: dict[str, dict] = {}
        for gid, season, ctype, detail, mag in rows:
            g = games.setdefault(gid, {"season": season, "caveats": [], "hard": False})
            g["caveats"].append({"caveat_type": ctype, "detail": detail, "magnitude": mag})
            ceil = CEILINGS.get(ctype)
            if mag is not None and ceil is not None and mag > ceil:
                g["hard"] = True

        print(f"{len(games)} caveated game(s) -> re-quarantine for review:")
        for gid, g in sorted(games.items()):
            kinds = ",".join(sorted({c["caveat_type"] for c in g["caveats"]}))
            print(f"  {gid} ({g['season']}) {kinds}{' [hard]' if g['hard'] else ''}")
        if not args.apply:
            print("\nPREVIEW only. Re-run with --apply to execute."); return 0

        cur = conn.cursor()
        qrows = []
        for gid, g in games.items():
            qrows.append(v2.quarantine_row(gid, g["season"],
                         "guard_blocker" if g["hard"] else "data_discrepancy", "guard",
                         "re-quarantined (was admitted-on-caveat): "
                         + "; ".join(c["detail"] for c in g["caveats"][:5]),
                         {"caveats": g["caveats"]}))
        ids = list(games.keys())
        ph = ",".join(["%s"] * len(ids))
        for t in FLAT_TABLES:
            cur.execute(f"DELETE FROM ZK_NBA_V2.FLAT.{t} WHERE game_id IN ({ph})", tuple(ids))
        v2.insert_quarantine(cur, qrows)
        conn.commit(); cur.close()
        print(f"\nApplied: {len(ids)} games re-quarantined, removed from {len(FLAT_TABLES)} tables. "
              f"data_caveats is now empty until approvals (dev/_approve.py).")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
