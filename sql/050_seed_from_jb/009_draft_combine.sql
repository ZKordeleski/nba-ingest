-- Seed ZK_NBA.FLAT.draft_combine from JB_HISTORIC_NBA.PUBLIC.DRAFT_COMBINE_STATS.
--
-- Pattern: TRUNCATE + INSERT (preserves DDL comments/PK).
--
-- DRAFT_COMBINE_STATS has ~1,202 rows. The source table has 80+ columns,
-- including 27 individual shot-spot accuracy columns (SPOT_FIFTEEN_CORNER_LEFT,
-- SPOT_NBA_BREAK_RIGHT, ...). FLAT.draft_combine intentionally captures only the
-- physical and athletic measurements; per-shot-spot data remains in the source
-- for whoever wants to slice it.
--
-- COLUMN MAP (via DESCRIBE 2026-05-14):
--   - HEIGHT_WO_SHOES (NUMBER 38,2), WEIGHT (NUMBER 38,2), WINGSPAN (NUMBER 38,2)
--   - STANDING_REACH (NUMBER 38,1), HAND_LENGTH/HAND_WIDTH (NUMBER 38,2)
--   - STANDING_VERTICAL_LEAP (NUMBER 38,2), MAX_VERTICAL_LEAP (NUMBER 38,1)
--   - LANE_AGILITY_TIME (NUMBER 38,2), BENCH_PRESS (NUMBER 38,1)
--   - THREE_QUARTER_SPRINT (NUMBER 38,2)
--   - SHUTTLE_RUN does NOT exist in source — left NULL.
--   - spot_up_pct / off_drib_pct dropped — source has 27 individual spot
--     columns; aggregating is judgment-call territory, leave for analysis tier.
--
-- All numeric columns are NUMBER(38,n) — use ::FLOAT or ::INT directly.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

TRUNCATE TABLE ZK_NBA.FLAT.draft_combine;

INSERT INTO ZK_NBA.FLAT.draft_combine (
    player_id, player_name, season, position,
    height, weight, wingspan, standing_reach, hand_length, hand_width,
    standing_vert, max_vert, bench, lane_agility, shuttle_run,
    three_quarter_sprint, spot_up_pct, off_drib_pct, fetched_at
)
SELECT
    PLAYER_ID::STRING                       AS player_id,
    TRIM(PLAYER_NAME)                       AS player_name,
    SEASON::INT                             AS season,
    TRIM(POSITION)                          AS position,
    HEIGHT_WO_SHOES::FLOAT                  AS height,
    WEIGHT::FLOAT                           AS weight,
    WINGSPAN::FLOAT                         AS wingspan,
    STANDING_REACH::FLOAT                   AS standing_reach,
    HAND_LENGTH::FLOAT                      AS hand_length,
    HAND_WIDTH::FLOAT                       AS hand_width,
    STANDING_VERTICAL_LEAP::FLOAT           AS standing_vert,
    MAX_VERTICAL_LEAP::FLOAT                AS max_vert,
    BENCH_PRESS::INT                        AS bench,
    LANE_AGILITY_TIME::FLOAT                AS lane_agility,
    NULL::FLOAT                             AS shuttle_run,
    THREE_QUARTER_SPRINT::FLOAT             AS three_quarter_sprint,
    NULL::FLOAT                             AS spot_up_pct,
    NULL::FLOAT                             AS off_drib_pct,
    CURRENT_TIMESTAMP()                     AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.DRAFT_COMBINE_STATS;

SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.draft_combine;
SELECT MIN(season) AS min_season, MAX(season) AS max_season FROM ZK_NBA.FLAT.draft_combine;
SELECT COUNT(*) AS has_wingspan FROM ZK_NBA.FLAT.draft_combine WHERE wingspan IS NOT NULL;
