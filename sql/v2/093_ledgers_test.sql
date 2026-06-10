-- Exception-ledger + survivor-bias-closer test — WRITTEN ALONGSIDE THE BUILD.
-- Covers what applies pre-quarantine-migration: the audit_findings inbox exists,
-- and the new ABSENCE/honesty invariants hold on the landed data. The rich
-- quarantine schema is validated separately at the post-backfill gate (061).
--   .venv/bin/python dev/apply_sql.py sql/v2/093_ledgers_test.sql
-- Headline: #1 (the durable "pending judgment" inbox exists) and #2/#3/#4 (the
-- audit can now see ABSENCE and orientation, not just in-range anomalies).

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

SELECT * FROM (
    -- 1. the pending-judgment ledger exists with its full vocabulary
    SELECT 1 AS ord, 'audit_findings inbox exists (>=10 cols incl. status/first_seen)' AS check_name,
           (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_schema='FLAT' AND table_name='AUDIT_FINDINGS') >= 10
           AND (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_schema='FLAT' AND table_name='AUDIT_FINDINGS'
                AND column_name IN ('FINDING_KEY','DETECTOR','SCOPE','STATUS','FIRST_SEEN_AT')) = 5 AS passed,
           'cols=' || (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_schema='FLAT' AND table_name='AUDIT_FINDINGS') AS detail

    -- 2. ABSENCE: no game loaded without box rows (the 2-teams check's blind spot)
    UNION ALL SELECT 2, 'no zero-box games (a game with no player_box is invisible to 2-teams)',
           (SELECT COUNT(*) FROM games g
              WHERE NOT EXISTS (SELECT 1 FROM player_box_basic b WHERE b.game_id=g.game_id)) = 0,
           'zero_box=' || (SELECT COUNT(*) FROM games g
              WHERE NOT EXISTS (SELECT 1 FROM player_box_basic b WHERE b.game_id=g.game_id))

    -- 3. ORIENTATION: home is BR-canonically the slug's trailing code. 0 mismatches
    -- = no silent home/away swap (and no benign divergence yet to allowlist).
    UNION ALL SELECT 3, 'orientation: home_team_abbr == slug home (RIGHT 3) for all games',
           (SELECT COUNT(*) FROM games WHERE home_team_abbr <> RIGHT(game_id,3)) = 0,
           'mismatches=' || (SELECT COUNT(*) FROM games WHERE home_team_abbr <> RIGHT(game_id,3))

    -- 4. RANGE: team scores within the historical envelope (1950 FTW 19-18 is the floor)
    UNION ALL SELECT 4, 'team pts within [15,200] and never NULL',
           (SELECT COUNT(*) FROM games
              WHERE home_pts IS NULL OR away_pts IS NULL
                 OR home_pts NOT BETWEEN 15 AND 200 OR away_pts NOT BETWEEN 15 AND 200) = 0,
           'out_of_range=' || (SELECT COUNT(*) FROM games
              WHERE home_pts IS NULL OR away_pts IS NULL
                 OR home_pts NOT BETWEEN 15 AND 200 OR away_pts NOT BETWEEN 15 AND 200)

    -- 5. CAVEAT HONESTY: no caveat type proliferates (>3% of a season's games) —
    -- the admit-with-caveat surface is per-game imperfection, not a masked bug.
    UNION ALL SELECT 5, 'no caveat-type proliferation (<3% of any season''s games)',
           (SELECT COUNT(*) FROM (
              SELECT g.season, c.caveat_type,
                     COUNT(DISTINCT c.game_id)*100.0
                       / NULLIF((SELECT COUNT(*) FROM games gg WHERE gg.season=g.season),0) AS pct
              FROM data_caveats c JOIN games g USING(game_id) GROUP BY 1,2
            ) WHERE pct > 3) = 0,
           'proliferating_types=' || (SELECT COUNT(*) FROM (
              SELECT g.season, c.caveat_type,
                     COUNT(DISTINCT c.game_id)*100.0
                       / NULLIF((SELECT COUNT(*) FROM games gg WHERE gg.season=g.season),0) AS pct
              FROM data_caveats c JOIN games g USING(game_id) GROUP BY 1,2
            ) WHERE pct > 3)

    -- 6. the worklist view exists (DERIVED.vw_open_findings)
    UNION ALL SELECT 6, 'DERIVED.vw_open_findings worklist view exists',
           (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS
              WHERE table_schema='DERIVED' AND table_name='VW_OPEN_FINDINGS') = 1,
           'view_present=' || (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS
              WHERE table_schema='DERIVED' AND table_name='VW_OPEN_FINDINGS')
)
ORDER BY ord;
