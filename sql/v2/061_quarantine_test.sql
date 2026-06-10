-- Rich-quarantine migration test — RUN AT THE POST-BACKFILL GATE, right after
-- applying sql/v2/060_quarantine.sql:
--   .venv/bin/python dev/apply_sql.py sql/v2/061_quarantine_test.sql
-- Verifies the game-grain worklist schema + that the slug-derived fields landed
-- (a quarantine row is never empty) + the rate view exists.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

SELECT * FROM (
    -- 1. game-grain schema in place (the columns that make it a worklist)
    SELECT 1 AS ord, 'quarantine is game-grain worklist (season/date/reason_class/status/context)' AS check_name,
           (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_schema='FLAT' AND table_name='QUARANTINE'
                AND column_name IN ('SEASON','GAME_DATE','HOME_TEAM_ABBR','REASON_CLASS',
                                    'FAILURE_STAGE','CONTEXT','STATUS','FIRST_SEEN_AT')) = 8 AS passed,
           'rich_cols=' || (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_schema='FLAT' AND table_name='QUARANTINE'
                AND column_name IN ('SEASON','GAME_DATE','HOME_TEAM_ABBR','REASON_CLASS',
                                    'FAILURE_STAGE','CONTEXT','STATUS','FIRST_SEEN_AT')) AS detail

    -- 2. a quarantine row is NEVER empty — slug-derived fields always present
    UNION ALL SELECT 2, 'every quarantine row has season/game_date/home (slug-derived, never empty)',
           (SELECT COUNT(*) FROM quarantine
              WHERE season IS NULL OR game_date IS NULL OR home_team_abbr IS NULL) = 0,
           'empty_rows=' || (SELECT COUNT(*) FROM quarantine
              WHERE season IS NULL OR game_date IS NULL OR home_team_abbr IS NULL)

    -- 3. reason_class is a constrained vocabulary (no stray free-text classes)
    UNION ALL SELECT 3, 'reason_class in the known taxonomy',
           (SELECT COUNT(*) FROM quarantine
              WHERE reason_class NOT IN ('fetch_error','missing_table','no_team_totals','guard_blocker','line_score_blocker')) = 0,
           'off_taxonomy=' || (SELECT COUNT(*) FROM quarantine
              WHERE reason_class NOT IN ('fetch_error','missing_table','no_team_totals','guard_blocker','line_score_blocker'))

    -- 4. DRAIN invariant: no game is BOTH loaded and quarantined-open
    UNION ALL SELECT 4, 'drain holds: no game both loaded and open-quarantined',
           (SELECT COUNT(*) FROM quarantine q WHERE q.status='open'
              AND EXISTS (SELECT 1 FROM games g WHERE g.game_id=q.game_id)) = 0,
           'overlap=' || (SELECT COUNT(*) FROM quarantine q WHERE q.status='open'
              AND EXISTS (SELECT 1 FROM games g WHERE g.game_id=q.game_id))

    -- 5. the completeness-ally rate view exists
    UNION ALL SELECT 5, 'DERIVED.vw_quarantine_rate exists',
           (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS
              WHERE table_schema='DERIVED' AND table_name='VW_QUARANTINE_RATE') = 1,
           'view_present=' || (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS
              WHERE table_schema='DERIVED' AND table_name='VW_QUARANTINE_RATE')
)
ORDER BY ord;
