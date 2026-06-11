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

import argparse
import logging
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

from nba_ingest.snowflake_client import connect, execute
from nba_ingest.v2.slice import enumerate_season_by_schedule

logging.basicConfig(level=logging.WARNING)
DB = "ZK_NBA_V2.FLAT"
FLAGS: list[str] = []
OKS: list[str] = []
# Structured, persisted findings — the durable "pending judgment" inbox
# (FLAT.audit_findings). New detectors call finding(); legacy detectors still
# use flag()/ok() for console-only output.
FINDINGS: list[dict] = []


def flag(name, detail):
    FLAGS.append(f"  ⚠ {name}: {detail}")


def ok(name, detail=""):
    OKS.append(f"  ✓ {name}{(' — ' + detail) if detail else ''}")


def finding(detector, scope, subject_id, detail, severity="warn", metric_value=None):
    """Record a structured finding (persisted to audit_findings) AND surface it on
    the console. finding_key = detector:subject dedupes across runs (MERGE)."""
    FINDINGS.append({"finding_key": f"{detector}:{subject_id}", "detector": detector,
                     "scope": scope, "subject_id": str(subject_id), "severity": severity,
                     "detail": detail, "metric_value": metric_value})
    FLAGS.append(f"  ⚠ {detector} [{subject_id}]: {detail}")


def persist_findings(conn):
    """MERGE findings into audit_findings: bump last_seen on recurrence, insert new,
    never auto-close (we judge). No-op if the table is absent (pre-070 apply)."""
    if not FINDINGS:
        return
    cur = conn.cursor()
    try:
        for f in FINDINGS:
            cur.execute(
                f"""MERGE INTO {DB}.audit_findings t
                    USING (SELECT %s AS k) s ON t.finding_key = s.k
                    WHEN MATCHED THEN UPDATE SET last_seen_at=CURRENT_TIMESTAMP(),
                        detail=%s, metric_value=%s, severity=%s
                    WHEN NOT MATCHED THEN INSERT
                        (finding_key, detector, scope, subject_id, severity, detail,
                         metric_value, first_seen_at, last_seen_at, status)
                        VALUES (%s,%s,%s,%s,%s,%s,%s,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP(),'open')""",
                (f["finding_key"], f["detail"], f["metric_value"], f["severity"],
                 f["finding_key"], f["detector"], f["scope"], f["subject_id"],
                 f["severity"], f["detail"], f["metric_value"]))
        conn.commit()
    finally:
        cur.close()


def q1(conn, sql):
    return execute(conn, sql)[0][0]


def main(check_completeness=False):
    conn = connect()
    try:
        seasons = [r[0] for r in execute(conn, f"SELECT DISTINCT season FROM {DB}.games ORDER BY season")]
        print(f"AUDIT ZK_NBA_V2 — seasons present: {seasons}\n")

        # 1. UNIQUENESS  (excluding rows adjudicated as player_id_collision caveats)
        for tbl, key in [("games", "game_id"), ("player_box_advanced", "game_id||'|'||player_id"),
                         ("line_scores", "game_id"), ("playoff_series", "series_slug")]:
            d = q1(conn, f"SELECT COUNT(*)-COUNT(DISTINCT {key}) FROM {DB}.{tbl}")
            (flag if d else ok)(f"uniqueness {tbl}", f"{d} duplicate keys")
        # player_box_basic: count dup (game_id,player_id) NOT explained by a collision caveat
        pbb_dups = q1(conn, f"""SELECT COUNT(*) FROM (
            SELECT game_id, player_id FROM {DB}.player_box_basic GROUP BY 1,2 HAVING COUNT(*)>1) d
          WHERE NOT EXISTS (SELECT 1 FROM {DB}.data_caveats c
            WHERE c.caveat_type='player_id_collision' AND c.game_id=d.game_id AND c.player_id=d.player_id)""")
        (flag if pbb_dups else ok)("uniqueness player_box_basic (un-caveated)", f"{pbb_dups} unexplained dup keys")

        # 2. RECONCILE  (excluding games adjudicated as reconciliation_discrepancy caveats)
        box_vs_team = q1(conn, f"""
          WITH tp AS (SELECT game_id, team_abbr, SUM(pts) s FROM {DB}.player_box_basic GROUP BY 1,2)
          SELECT COUNT(*) FROM tp JOIN {DB}.games g ON tp.game_id=g.game_id
          WHERE tp.s <> CASE WHEN tp.team_abbr=g.home_team_abbr THEN g.home_pts
                             WHEN tp.team_abbr=g.away_team_abbr THEN g.away_pts END
            AND tp.game_id NOT IN (SELECT game_id FROM {DB}.data_caveats WHERE caveat_type='reconciliation_discrepancy')""")
        (flag if box_vs_team else ok)("reconcile box vs team total (un-caveated)", f"{box_vs_team} unexplained mismatches")

        ls_quarters = q1(conn, f"""SELECT COUNT(*) FROM {DB}.line_scores
          WHERE (COALESCE(home_q1,0)+COALESCE(home_q2,0)+COALESCE(home_q3,0)+COALESCE(home_q4,0)
                +COALESCE(home_ot1,0)+COALESCE(home_ot2,0)+COALESCE(home_ot3,0)+COALESCE(home_ot4,0) <> home_pts
             OR COALESCE(away_q1,0)+COALESCE(away_q2,0)+COALESCE(away_q3,0)+COALESCE(away_q4,0)
                +COALESCE(away_ot1,0)+COALESCE(away_ot2,0)+COALESCE(away_ot3,0)+COALESCE(away_ot4,0) <> away_pts)
            AND game_id NOT IN (SELECT game_id FROM {DB}.data_caveats WHERE caveat_type='line_score_discrepancy')""")
        (flag if ls_quarters else ok)("reconcile line-score quarters vs final (un-caveated)", f"{ls_quarters} unexplained")

        ls_vs_games = q1(conn, f"""SELECT COUNT(*) FROM {DB}.line_scores l JOIN {DB}.games g USING(game_id)
          WHERE (l.home_pts<>g.home_pts OR l.away_pts<>g.away_pts)
            AND l.game_id NOT IN (SELECT game_id FROM {DB}.data_caveats WHERE caveat_type='line_score_discrepancy')""")
        (flag if ls_vs_games else ok)("reconcile line-score vs games total (un-caveated)", f"{ls_vs_games} unexplained")

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

        # ─── ABSENCE & honesty detectors (the survivor-bias closers) ───────────
        # 7. ZERO-BOX: a game in `games` with NO player_box rows is invisible to
        # the 2-teams check (GROUP BY yields no row). Closes that referential hole.
        zero_box = q1(conn, f"""SELECT COUNT(*) FROM {DB}.games g
          WHERE NOT EXISTS (SELECT 1 FROM {DB}.player_box_basic b WHERE b.game_id=g.game_id)""")
        if zero_box:
            finding("zero_box_games", "game", "all",
                    f"{zero_box} loaded games have NO player_box rows (invisible to the 2-teams check)",
                    "error", zero_box)
        else:
            ok("zero_box_games", "every game has box rows")

        # 8. ORIENTATION backstop: home is BR-canonically the slug's trailing code.
        # A mismatch = the order-fallback fired (possible home/away swap) OR a benign
        # slug/abbr divergence. Always flag for judgment; each is reviewed individually.
        # We do NOT auto-learn an allowlist — guards don't auto-loosen.
        n_mism = q1(conn, f"SELECT COUNT(*) FROM {DB}.games WHERE home_team_abbr <> RIGHT(game_id,3)")
        if n_mism:
            sample = [r[0] for r in execute(conn,
                f"SELECT game_id FROM {DB}.games WHERE home_team_abbr <> RIGHT(game_id,3) LIMIT 6")]
            finding("orientation", "game", "backstop",
                    f"{n_mism} games where home_team_abbr != slug home (RIGHT 3); sample {sample} "
                    f"— adjudicate swap vs benign abbr divergence", "warn", n_mism)
        else:
            ok("orientation backstop", "home_team_abbr == slug home for all games")

        # 9. RANGE team pts: `games` had only a tie check. Bound team scores. The 1950
        # Fort Wayne 19-18 Minneapolis game (18) is the real historical floor.
        bad_pts = q1(conn, f"""SELECT COUNT(*) FROM {DB}.games
          WHERE home_pts IS NULL OR away_pts IS NULL
             OR home_pts NOT BETWEEN 15 AND 200 OR away_pts NOT BETWEEN 15 AND 200""")
        if bad_pts:
            finding("range_team_pts", "game", "all",
                    f"{bad_pts} games with team pts NULL or outside [15,200]", "error", bad_pts)
        else:
            ok("range_team_pts", "all team scores in [15,200]")

        # 10. CAVEAT RATE: admit-with-caveat must not become a suppression dumping
        # ground. Proliferation of one type = a systematic bug, not per-game imperfection.
        # (A caveat already suppresses ONLY its own detector — a caveated game still
        # runs every other check; this guards the *rate*.) Baseline ~0.14%.
        gps = {s: q1(conn, f"SELECT COUNT(*) FROM {DB}.games WHERE season={s}") for s in seasons}
        for s, ctype, n in execute(conn, f"""SELECT g.season, c.caveat_type, COUNT(DISTINCT c.game_id)
              FROM {DB}.data_caveats c JOIN {DB}.games g USING(game_id) GROUP BY 1,2"""):
            tot = gps.get(s) or 1
            frac = n / tot
            if frac > 0.03 and n >= 5:
                finding("caveat_rate", "season", f"{s}:{ctype}",
                        f"{n}/{tot} games ({frac:.1%}) carry {ctype} — proliferation; "
                        f"systematic bug rather than per-game imperfection?", "warn", round(frac, 4))
            else:
                ok(f"caveat_rate {s} {ctype}", f"{n}/{tot} ({frac:.1%}) within baseline")

        # 11. QUARANTINE RATE: a per-era spike = systematic parse failure masquerading
        # as "that era was just bad data". Schema-aware (rich quarantine only).
        qcols = {r[0].lower() for r in execute(conn, f"""SELECT column_name
            FROM ZK_NBA_V2.INFORMATION_SCHEMA.COLUMNS
            WHERE table_schema='FLAT' AND table_name='QUARANTINE'""")}
        if {"season", "reason_class"} <= qcols:
            for s, qn in execute(conn, f"SELECT season, COUNT(*) FROM {DB}.quarantine WHERE status='open' GROUP BY 1"):
                tot = (gps.get(s) or 0) + qn
                rate = qn / tot if tot else 0
                if rate > 0.05 and qn >= 3:
                    finding("quarantine_rate", "season", s,
                            f"{qn}/{tot} games ({rate:.1%}) quarantined — systematic parse failure for this era?",
                            "warn", round(rate, 4))
                else:
                    ok(f"quarantine_rate {s}", f"{qn} quarantined ({rate:.1%})")
        else:
            ok("quarantine_rate", "legacy quarantine schema (pre-060 migration) — rate profiling deferred")

        # 12. COMPLETENESS (gated; re-fetches schedule pages): the only detector that
        # looks at what ISN'T there. Every scheduled game must be loaded OR quarantined;
        # the residual = silently dropped. Catches the demonstrated failure mode.
        if check_completeness:
            quar_all = {r[0] for r in execute(conn, f"SELECT game_id FROM {DB}.quarantine")}
            for s in seasons:
                loaded = {r[0] for r in execute(conn, f"SELECT game_id FROM {DB}.games WHERE season={s}")}
                try:
                    enumerated = set(enumerate_season_by_schedule(s))
                except Exception as exc:  # noqa: BLE001
                    flag(f"completeness {s}", f"could not enumerate schedule: {exc!r}")
                    continue
                missing = enumerated - loaded - quar_all
                if missing:
                    finding("completeness", "season", s,
                            f"{len(missing)} scheduled games neither loaded nor quarantined "
                            f"(sample {sorted(missing)[:5]})", "error", len(missing))
                else:
                    ok(f"completeness {s}", f"{len(enumerated)} scheduled = {len(loaded)} loaded + quarantined")
        else:
            ok("completeness", "skipped (pass --completeness; re-fetches schedule pages)")

        # 13. LINE-SCORE COMPLETENESS (raise absence, don't reconcile it): a present
        # line_scores row should have complete regulation quarters, and every game
        # should have a line score. Incomplete/absent is EXPECTED in early eras (the
        # metric_coverage 'line_score_quarters' ramp) — so we flag the OUTLIERS:
        # incompleteness in a season that is otherwise >=90% complete (a NEW anomaly,
        # e.g. a modern game missing quarters). A uniformly-sparse season is the era
        # ramp (documented), not flagged. Data-driven boundary — no hardcoded year.
        for s in seasons:
            gn = q1(conn, f"SELECT COUNT(*) FROM {DB}.games WHERE season={s}")
            if not gn:
                continue
            complete = q1(conn, f"""SELECT COUNT(*) FROM {DB}.games g JOIN {DB}.line_scores l USING(game_id)
              WHERE g.season={s}
                AND l.home_q1 IS NOT NULL AND l.home_q2 IS NOT NULL AND l.home_q3 IS NOT NULL AND l.home_q4 IS NOT NULL
                AND l.away_q1 IS NOT NULL AND l.away_q2 IS NOT NULL AND l.away_q3 IS NOT NULL AND l.away_q4 IS NOT NULL""")
            rate = complete / gn
            if rate >= 0.9 and complete < gn:
                finding("line_score_completeness", "season", s,
                        f"{gn - complete}/{gn} games lack a complete line score in an otherwise-complete "
                        f"season ({rate:.0%}) — anomaly (a complete-era game should have all quarters)",
                        "warn", gn - complete)
            else:
                ok(f"line_score_completeness {s}",
                   f"{rate:.0%} complete" + ("" if rate >= 0.9 else " — era ramp (metric_coverage line_score_quarters)"))

        persist_findings(conn)

    finally:
        conn.close()

    print(f"=== {len(FLAGS)} FLAGS (adjudicate) ===")
    print("\n".join(FLAGS) if FLAGS else "  (none)")
    print(f"\n=== {len(OKS)} OK ===")
    print("\n".join(OKS))
    print(f"\n{len(FINDINGS)} structured findings persisted to audit_findings "
          f"(query DERIVED.vw_open_findings).")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="ZK_NBA_V2 anomaly audit")
    ap.add_argument("--completeness", action="store_true",
                    help="run the schedule-reconciliation completeness check (re-fetches schedule pages)")
    args = ap.parse_args()
    main(check_completeness=args.completeness)
