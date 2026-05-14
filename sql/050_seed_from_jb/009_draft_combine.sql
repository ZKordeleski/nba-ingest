-- Seed ZK_NBA.FLAT.draft_combine from JB_HISTORIC_NBA.PUBLIC.DRAFT_COMBINE_STATS.
--
-- DRAFT_COMBINE_STATS has 1,202 rows.
-- IMPORTANT: Run DESCRIBE first to confirm exact column names in JB.
-- The mapping below uses commonly expected NBA API column names — verify each
-- against the actual schema before running.
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- Step 1: confirm column names (run this first, paste results here)
DESCRIBE TABLE JB_HISTORIC_NBA.PUBLIC.DRAFT_COMBINE_STATS;

-- Step 2: after confirming column names, run the CTAS below.
-- Adjust column names in the SELECT if they differ from what's shown.
CREATE OR REPLACE TABLE ZK_NBA.FLAT.draft_combine AS
SELECT
    PLAYER_ID::STRING                       AS player_id,
    TRIM(FIRST_NAME) || ' ' || TRIM(LAST_NAME) AS player_name,
    TRY_TO_NUMBER(SEASON)                   AS season,
    TRIM(POSITION)                          AS position,
    TRY_TO_DOUBLE(HEIGHT_WO_SHOES)          AS height,
    TRY_TO_DOUBLE(WEIGHT)                   AS weight,
    TRY_TO_DOUBLE(WINGSPAN)                 AS wingspan,
    TRY_TO_DOUBLE(STANDING_REACH)           AS standing_reach,
    TRY_TO_DOUBLE(HAND_LENGTH)              AS hand_length,
    TRY_TO_DOUBLE(HAND_WIDTH)               AS hand_width,
    TRY_TO_DOUBLE(STANDING_VERTICAL_LEAP)   AS standing_vert,
    TRY_TO_DOUBLE(MAX_VERTICAL_LEAP)        AS max_vert,
    TRY_TO_NUMBER(BENCH_PRESS)              AS bench,
    TRY_TO_DOUBLE(LANE_AGILITY_TIME)        AS lane_agility,
    TRY_TO_DOUBLE(SHUTTLE_RUN)              AS shuttle_run,
    TRY_TO_DOUBLE(THREE_QUARTER_SPRINT)     AS three_quarter_sprint,
    TRY_TO_DOUBLE(SPOT_FIFTEEN_CORNER_LEFT) AS spot_up_pct,   -- Approximate: use a shooting stat if available
    NULL::FLOAT                             AS off_drib_pct,   -- May not exist in JB; check DESCRIBE output
    CURRENT_TIMESTAMP()                     AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.DRAFT_COMBINE_STATS;

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.draft_combine;
-- Expected: ~1,202

SELECT MIN(season) AS min_season, MAX(season) AS max_season FROM ZK_NBA.FLAT.draft_combine;
