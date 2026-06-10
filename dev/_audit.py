"""Anomaly-surfacing audit for ZK_NBA_V2 — the systematic answer to survivor bias.

Instead of hand-writing a clever query each time we wonder "what did we miss?",
this runs generic detectors for the CLASSES of problem we keep hitting, over every
table and season, and FLAGS deviations for a human/agent to adjudicate
(era-reality vs bug). The system finds; we judge.

Detectors:
  1. UNIQUENESS   — primary-key duplicates (e.g. the George-Johnson collision)
  2. RECONCILE    — box player-pts vs team total; line-score quarters vs final;
                    line-score total vs games total (cross-table)
  3. RANGE        — basketball domain bounds (made<=att, pct in [0,1], pts, ties)
  4. REFERENTIAL  — orphans across tables; every game has exactly 2 teams in the box
  5. PROFILE      — GENERIC: per-column null-rate by season; flags all-null,
                    degenerate (1 distinct value), and era-boundary JUMPS in
                    null-rate (the cliff/ramp signal). Catches unknown-unknowns.
  6. COVERAGE     — data vs metric_coverage's own claims (registry checks itself)

Read-only. Run: .venv/bin/python dev/_audit.py
"""

from __future__ import annotations

import logging
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

from nba_ingest.snowflake_client import connect, execute

logging.basicConfig(level=logging.WARNING)
DB = "ZK_NBA_V2.FLAT"
FLAGS: list[str] = []
OKS: list[str] = []


def flag(name, detail):
    FLAGS.append(f"  ⚠ {name}: {detail}")


def ok(name, detail=""):
    OKS.append(f"  ✓ {name}{(' — ' + detail) if detail else ''}")


def q1(conn, sql):
    return execute(conn, sql)[0][0]


def main():
    conn = connect()
    try:
        seasons = [r[0] for r in execute(conn, f"SELECT DISTINCT season FROM {DB}.games ORDER BY season")]
        print(f"AUDIT ZK_NBA_V2 — seasons present: {seasons}\n")

        # 1. UNIQUENESS
        for tbl, key in [("games", "game_id"), ("player_box_basic", "game_id||'|'||player_id"),
                         ("player_box_advanced", "game_id||'|'||player_id"), ("line_scores", "game_id"),
                         ("playoff_series", "series_slug")]:
            d = q1(conn, f"SELECT COUNT(*)-COUNT(DISTINCT {key}) FROM {DB}.{tbl}")
            (flag if d else ok)(f"uniqueness {tbl}", f"{d} duplicate keys")

        # 2. RECONCILE
        box_vs_team = q1(conn, f"""
          WITH tp AS (SELECT game_id, team_abbr, SUM(pts) s FROM {DB}.player_box_basic GROUP BY 1,2)
          SELECT COUNT(*) FROM tp JOIN {DB}.games g ON tp.game_id=g.game_id
          WHERE tp.s <> CASE WHEN tp.team_abbr=g.home_team_abbr THEN g.home_pts
                             WHEN tp.team_abbr=g.away_team_abbr THEN g.away_pts END""")
        (flag if box_vs_team else ok)("reconcile box vs team total", f"{box_vs_team} mismatched team-games")

        ls_quarters = q1(conn, f"""SELECT COUNT(*) FROM {DB}.line_scores
          WHERE COALESCE(home_q1,0)+COALESCE(home_q2,0)+COALESCE(home_q3,0)+COALESCE(home_q4,0)
                +COALESCE(home_ot1,0)+COALESCE(home_ot2,0)+COALESCE(home_ot3,0)+COALESCE(home_ot4,0) <> home_pts
             OR COALESCE(away_q1,0)+COALESCE(away_q2,0)+COALESCE(away_q3,0)+COALESCE(away_q4,0)
                +COALESCE(away_ot1,0)+COALESCE(away_ot2,0)+COALESCE(away_ot3,0)+COALESCE(away_ot4,0) <> away_pts""")
        (flag if ls_quarters else ok)("reconcile line-score quarters vs final", f"{ls_quarters} games where periods != total")

        ls_vs_games = q1(conn, f"""SELECT COUNT(*) FROM {DB}.line_scores l JOIN {DB}.games g USING(game_id)
          WHERE l.home_pts<>g.home_pts OR l.away_pts<>g.away_pts""")
        (flag if ls_vs_games else ok)("reconcile line-score vs games total", f"{ls_vs_games} games disagree")

        # 3. RANGE
        rng = q1(conn, f"""SELECT COUNT(*) FROM {DB}.player_box_basic
          WHERE fgm>fga OR fg3m>fg3a OR ftm>fta OR pts<0 OR pts>105
             OR fg_pct<0 OR fg_pct>1 OR fg3_pct<0 OR fg3_pct>1 OR ft_pct<0 OR ft_pct>1""")
        (flag if rng else ok)("range player_box_basic", f"{rng} domain violations")
        ties = q1(conn, f"SELECT COUNT(*) FROM {DB}.games WHERE home_pts=away_pts")
        (flag if ties else ok)("range no tie games", f"{ties} ties")

        # 4. REFERENTIAL
        orphan_box = q1(conn, f"SELECT COUNT(*) FROM {DB}.player_box_basic b LEFT JOIN {DB}.games g USING(game_id) WHERE g.game_id IS NULL")
        (flag if orphan_box else ok)("referential player_box has game", f"{orphan_box} orphan box rows")
        orphan_adv = q1(conn, f"""SELECT COUNT(*) FROM {DB}.player_box_advanced a
          LEFT JOIN {DB}.player_box_basic b ON a.game_id=b.game_id AND a.player_id=b.player_id WHERE b.game_id IS NULL""")
        (flag if orphan_adv else ok)("referential advanced has basic", f"{orphan_adv} orphan advanced rows")
        bad_team_count = q1(conn, f"""SELECT COUNT(*) FROM
          (SELECT game_id, COUNT(DISTINCT team_abbr) n FROM {DB}.player_box_basic GROUP BY 1) WHERE n<>2""")
        (flag if bad_team_count else ok)("referential 2 teams per game", f"{bad_team_count} games without exactly 2 teams")

        # coverage-aware suppression: an era null-rate JUMP is EXPECTED if the
        # column maps to a metric_coverage boundary that explains it. Only
        # UNexplained jumps escalate to a flag (high signal, no era-jump noise).
        cov = {m: (f, st) for m, f, st in execute(conn,
            f"SELECT metric, first_tracked_season, status FROM {DB}.metric_coverage")}
        COVCOL = {"stl": "stl", "blk": "blk", "tov": "tov", "oreb": "oreb", "dreb": "dreb",
                  "fg3m": "fg3", "fg3a": "fg3", "fg3_pct": "fg3", "game_score": "game_score",
                  "minutes_played": "mp", "ast": "ast", "is_starter": "is_starter",
                  "plus_minus": "plus_minus",
                  "arena_state": "arena_state", "arena_name": "arena_name", "arena_city": "arena_name"}

        def explained(col, hi_null_seasons):
            base = col.lower().replace("home_", "").replace("away_", "")
            m = COVCOL.get(base, base)  # fallback: the base column name is the metric
            first, status = cov.get(m, (None, None))
            if status == "recording_ramp":   # gradual old-era sparsity is expected by design
                return True
            return bool(first and hi_null_seasons and all(s < first for s in hi_null_seasons))

        # 5. PROFILE (generic): per-column null-rate by season; flag all-null, degenerate, era jumps
        for tbl in ("player_box_basic", "games"):
            cols = [r[0] for r in execute(conn, f"""SELECT column_name FROM ZK_NBA_V2.INFORMATION_SCHEMA.COLUMNS
              WHERE table_schema='FLAT' AND table_name=UPPER('{tbl}')
                AND data_type IN ('NUMBER','FLOAT','TEXT','BOOLEAN') ORDER BY ordinal_position""")]
            for c in cols:
                rates = {}
                for s in seasons:
                    tot = q1(conn, f"SELECT COUNT(*) FROM {DB}.{tbl} WHERE season={s}")
                    if not tot:
                        continue
                    nulls = q1(conn, f"SELECT COUNT(*) FROM {DB}.{tbl} WHERE season={s} AND {c} IS NULL")
                    rates[s] = round(100.0 * nulls / tot, 1)
                if not rates:
                    continue
                # all-null in every season -> dead column
                if all(v == 100.0 for v in rates.values()):
                    flag(f"profile {tbl}.{c}", f"ALL-NULL in every season {rates} — dead column?")
                # era jump: null-rate differs by >50pts across seasons (cliff/ramp signal)
                elif max(rates.values()) - min(rates.values()) > 50:
                    hi = [s for s, v in rates.items() if v > 50]
                    if explained(c, hi):
                        ok(f"profile {tbl}.{c}", f"era jump EXPECTED via metric_coverage {rates}")
                    else:
                        flag(f"profile {tbl}.{c}", f"UNEXPLAINED null-rate jump {rates} — adjudicate")

        # 6. COVERAGE consistency: data before first_tracked_season is a REAL BUG only
        # for a CLIFF (did_not_exist_before); for a RAMP (official_complete_from) it's
        # the expected sporadic early data.
        cov = execute(conn, f"SELECT metric, first_tracked_season, status FROM {DB}.metric_coverage WHERE first_tracked_season IS NOT NULL")
        colmap = {"stl": "stl", "blk": "blk", "tov": "tov", "oreb": "oreb", "dreb": "dreb", "fg3": "fg3m"}
        for metric, first, status in cov:
            col = colmap.get(metric)
            if not col:
                continue
            early = q1(conn, f"SELECT COUNT(*) FROM {DB}.player_box_basic WHERE season < {first} AND {col} IS NOT NULL")
            if early and status == "did_not_exist_before":
                flag(f"coverage {metric}", f"{early} rows present before {first} but status=CLIFF — REAL bug (thing didn't exist)")
            elif early:
                ok(f"coverage {metric}", f"{early} pre-{first} rows = expected ramp (status={status})")
            else:
                ok(f"coverage {metric}", f"no data before {first}")

    finally:
        conn.close()

    print(f"=== {len(FLAGS)} FLAGS (adjudicate) ===")
    print("\n".join(FLAGS) if FLAGS else "  (none)")
    print(f"\n=== {len(OKS)} OK ===")
    print("\n".join(OKS))


if __name__ == "__main__":
    main()
