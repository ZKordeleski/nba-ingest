"""Backfill human provenance onto the legacy UNSIGNED caveats (reviewed_by IS NULL).

Unlike dev/_remediate_caveats.py (the one-time re-quarantine-everything migration),
this is the surgical, mixed-state tool: it touches ONLY the caveats that predate the
provenance system, leaves every already-signed caveat alone, and stamps each one with
an individual, evidence-grounded note built from THAT game's own numbers — never a
bulk rubber-stamp. The justifying evidence is recomputed per-game from our own loaded
data (box-score sums vs the final), so a caveat that no longer corroborates is HELD,
not signed.

Three classes, each with its own evidence framing:
  - line_score_discrepancy: per-quarter cells are incomplete/misattributed in early-era
    BR, but the final is corroborated 3 ways (line total == BR game final == box sum).
  - reconciliation_discrepancy: the player-level box is missing historical rows, so
    player-points fall short of BR's authoritative team total.
  - player_id_collision: two distinct same-name players share a resolved slug.

Plus two researched conflicts (BR self-contradicts by 2 pts), resolved via an
independent source (landofbasketball.com):
  - 195403010MLH: stored final (71) is WRONG; true 73 -> CORRECT games.home_pts + caveat.
  - 196312060SFW: stored final (101) is RIGHT; the line-score 103 is the artifact.

    dev/_remediate_provenance.py            # preview (default)
    dev/_remediate_provenance.py --apply    # execute
"""

from __future__ import annotations

import argparse
import collections
import re
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

from nba_ingest.snowflake_client import connect

REVIEWER = "zack"

# Per-game bespoke notes for the games whose evidence isn't the generic class story.
BESPOKE = {
    "197303150GSW": (
        "Provenance backfill (legacy collision). Two distinct players named George "
        "Johnson share resolved player_id johnsge02 in this 1973-03-15 game — one on "
        "GSW, one on HOU. They appear on OPPOSING teams in the same game, which is "
        "dispositive that they are two different people (a single player cannot play "
        "both sides). Real-but-imperfect: per-row slug resolution still owed (backlog). "
        "Admitted with caveat."
    ),
    "196312060SFW": (
        "Provenance backfill. Stored final (SFW 101) is correct: BR's game-header (101) "
        "and the independent landofbasketball.com (Lakers 110-101) agree. The line-score "
        "cell value (103) carries a +2 early-era source artifact; the final is reliable "
        "at 101. Researched 2026-06. Admitted with caveat."
    ),
    # MLH note is emitted with the score-correction path below.
}
MLH_GAME = "195403010MLH"
MLH_NOTE = (
    "Data correction + provenance. Stored final (MLH 71) was BR's game-header value; "
    "BR's own box score and line-score total (73) AND the independent landofbasketball.com "
    "(Hawks lost 73-78) all give 73. Corrected games.home_pts 71->73; caveat retained to "
    "document the corrected BR game-header artifact. Researched 2026-06."
)


def build_note(game_id, ctype, detail, boxsum, finals):
    """An individual, evidence-grounded note for one caveat, or None to HOLD it."""
    if game_id in BESPOKE:
        return BESPOKE[game_id]
    if game_id == MLH_GAME:
        return MLH_NOTE
    if ctype == "line_score_discrepancy":
        m = re.search(r"(home|away) line score: quarters=(\d+) total=(\d+) game=(\d+)", detail)
        if not m:
            return None
        side, q, total, game = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
        team = finals[game_id][f"{side}_team"]
        bs = boxsum.get(game_id, {}).get(team)
        if bs is None or not (bs == total == game):  # final must corroborate 3 ways
            return None
        return (
            f"Provenance backfill (legacy line-score discrepancy). {side.capitalize()} "
            f"per-quarter cells sum to {q}, but the final {game} is corroborated three "
            f"independent ways — line-score total ({total}), BR game final ({game}), and "
            f"box-score player-point sum ({bs}). Early-era BR quarter breakdown is "
            f"incomplete/misattributed; the final is reliable. Admitted with caveat."
        )
    if ctype == "reconciliation_discrepancy":
        m = re.search(r"(\w+): player-pts (\d+) != team total (\d+)", detail)
        if not m:
            return None
        team, pp, tt = m.group(1), int(m.group(2)), int(m.group(3))
        return (
            f"Provenance backfill (legacy reconciliation discrepancy). {team}'s box score "
            f"has incomplete historical player rows: available player points sum to {pp} vs "
            f"BR's official team total {tt} (short by {tt - pp}). BR team total is "
            f"authoritative for the final; the player-level box is known-incomplete for this "
            f"early-era game. Admitted with caveat."
        )
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="execute (default: preview only)")
    args = ap.parse_args()

    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT c.game_id, c.caveat_type, c.detail, g.home_team_abbr, g.away_team_abbr,
                   g.home_pts, g.away_pts
            FROM ZK_NBA_V2.FLAT.data_caveats c
            JOIN ZK_NBA_V2.FLAT.games g USING (game_id)
            WHERE c.reviewed_by IS NULL
            ORDER BY c.game_id, c.caveat_type, c.detail""")
        rows = cur.fetchall()
        finals = {}
        for gid, _ct, _d, ht, at, hp, ap_ in rows:
            finals[gid] = {"home_team": ht, "away_team": at, "home_pts": hp, "away_pts": ap_}
        gids = sorted(finals)
        ph = ",".join(["%s"] * len(gids))
        cur.execute(f"SELECT game_id, team_abbr, SUM(pts) FROM ZK_NBA_V2.FLAT.player_box_basic "
                    f"WHERE game_id IN ({ph}) GROUP BY game_id, team_abbr", tuple(gids))
        boxsum = collections.defaultdict(dict)
        for gid, team, s in cur.fetchall():
            boxsum[gid][team] = int(s) if s is not None else None

        sign, hold = [], []
        for gid, ct, detail, *_ in rows:
            note = build_note(gid, ct, detail, boxsum, finals)
            (sign if note else hold).append((gid, ct, detail, note))

        print(f"{len(rows)} unsigned caveats -> SIGN {len(sign)} / HOLD {len(hold)}\n")
        for gid, ct, detail, note in sign:
            print(f"  SIGN {gid} [{ct}]\n       evidence: {detail[:72]}\n       note: {note[:96]}...")
        if hold:
            print("\nHELD (no corroboration — needs individual review, NOT signed):")
            for gid, ct, detail, _ in hold:
                print(f"  HOLD {gid} [{ct}] {detail[:72]}")
        print(f"\nAlso: CORRECT games.home_pts for {MLH_GAME} 71 -> 73 (evidenced).")

        if not args.apply:
            print("\nPREVIEW only. Re-run with --apply to execute.")
            return 0

        # 1) the evidenced score correction
        cur.execute(f"UPDATE ZK_NBA_V2.FLAT.games SET home_pts=73 WHERE game_id=%s", (MLH_GAME,))
        # 2) stamp provenance per caveat (match the exact row by game+type+detail)
        n = 0
        for gid, ct, detail, note in sign:
            cur.execute("""
                UPDATE ZK_NBA_V2.FLAT.data_caveats
                SET reviewed_by=%s, reviewed_at=CURRENT_TIMESTAMP(), review_note=%s
                WHERE game_id=%s AND caveat_type=%s AND detail=%s AND reviewed_by IS NULL""",
                (REVIEWER, note, gid, ct, detail))
            n += cur.rowcount
        conn.commit()
        print(f"\nApplied: corrected {MLH_GAME}; signed {n} caveats; {len(hold)} held.")
        cur.close()
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
