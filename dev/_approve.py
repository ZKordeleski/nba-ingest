"""Approve quarantined games back into the dataset — the ONLY path that writes a
data_caveats row.

The strict guardrail (slice.build_game) quarantines ANY flagged game; it never
admits-on-caveat. A human reviews the quarantine worklist and approves the games
that are real-but-imperfect. This tool re-admits each approved game via
build_game(approve=True), which admits it AND records its flagged issues as typed
data_caveats rows stamped with the approval provenance (reviewed_by/at/note) — then
drains the quarantine entry. A caveat therefore always means "a human (named) approved
this game on this date knowing it carries this imperfection, for this reason."

FRICTION BY DESIGN: every game must be named explicitly (no bulk sweep), and a
reviewer + written rationale are mandatory. Approving one game never loosens the
guard for any other. Preview by default; --apply to execute:
    dev/_approve.py --game 195003160DNN --reviewer zack --note "BAA quarter cells partial; final score correct per BR"
    dev/_approve.py --game A --game B --reviewer zack --note "<rationale>" --apply
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

from nba_ingest.snowflake_client import connect
from nba_ingest.v2 import slice as v2

TABLES = ["games", "player_box_basic", "player_box_advanced", "line_scores",
          "game_officials", "game_inactives", "data_caveats"]


def main():
    ap = argparse.ArgumentParser()
    # FRICTION BY DESIGN: each game must be named explicitly (no --all / --reason-class
    # sweep), and a reviewer + written rationale are mandatory. Approving one game
    # never loosens the guard for any other — guards don't auto-loosen.
    ap.add_argument("--game", action="append", default=[], required=True,
                    help="game_id to approve (repeatable; you must name each one — no bulk)")
    ap.add_argument("--reviewer", required=True, help="who is approving (recorded as provenance)")
    ap.add_argument("--note", required=True, help="why this flagged game is admitted (the rationale)")
    ap.add_argument("--apply", action="store_true", help="execute (default: preview only)")
    args = ap.parse_args()

    conn = connect()
    try:
        cur = conn.cursor()
        ph = ",".join(["%s"] * len(args.game))
        cur.execute(f"SELECT game_id, season, reason_class, detail FROM ZK_NBA_V2.FLAT.quarantine "
                    f"WHERE status='open' AND game_id IN ({ph}) ORDER BY game_id", tuple(args.game))
        targets = cur.fetchall()
        cur.close()
        if not targets:
            print("No matching open quarantines for the named game(s)."); return 0
        missing = set(args.game) - {r[0] for r in targets}
        if missing:
            print(f"  (note: not open in quarantine, skipping: {sorted(missing)})")

        print(f"{len(targets)} game(s) to approve (re-admit + caveat):")
        for gid, season, rc, detail in targets:
            print(f"  {gid} ({season}) [{rc}] {detail[:80]}")
        if not args.apply:
            print("\nPREVIEW only. Re-run with --apply to execute."); return 0

        series_cache: dict[int, list] = {}
        n_ok = n_skip = n_cav = 0
        for gid, season, _rc, _detail in targets:
            if season not in series_cache:
                try:
                    series_cache[season] = v2.fetch_playoff_series(season)
                except v2.PlayoffsPageMissing:
                    series_cache[season] = []  # a human is already reviewing; no bracket this era
            try:
                res = v2.build_game(gid, season, series_cache[season], approve=True)
            except Exception as exc:  # noqa: BLE001
                print(f"  SKIP {gid}: rebuild error {exc!r}"); n_skip += 1; continue
            if isinstance(res, tuple):  # structural failure (no data) — cannot approve
                print(f"  SKIP {gid}: still unbuildable ({res[1]['detail']})"); n_skip += 1; continue
            # stamp every caveat with the approval provenance — the imperfection and
            # the human accountability for admitting it are one row.
            now = v2._now_utc()
            for c in res["data_caveats"]:
                c["reviewed_by"] = args.reviewer
                c["reviewed_at"] = now
                c["review_note"] = args.note
            cur = conn.cursor()
            for t in TABLES:
                v2.insert(cur, t, res[t])
            v2.drain_quarantine(cur, [gid])
            conn.commit(); cur.close()
            n_ok += 1; n_cav += len(res["data_caveats"])
            print(f"  OK {gid}: admitted, {len(res['data_caveats'])} caveat(s)")
        print(f"\nDONE. approved={n_ok} caveats_written={n_cav} skipped={n_skip}")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
