-- Seed ZK_NBA.FLAT.game_officials from JB_HISTORIC_NBA.PUBLIC.OFFICIALS.
--
-- OFFICIALS has 70,971 rows covering 23,575 games (modern only).
-- 235 distinct officials across the dataset.
--
-- PRE-SEED VALIDATION FINDINGS (run against JB source 2026-05-11):
--   - Official count distribution: 3 per game for 23,294 games (normal),
--     4 per game for 238 games (NBA Finals and special games — correct),
--     2 per game for 30 games (possible partial data for old games),
--     5 per game for 1 game and 6 per game for 12 games — JB LOAD ERRORS.
--   - 5 and 6 official games are deduplicated below (DISTINCT on all key fields).
--   - Do NOT assert COUNT(officials) = 3 per game — Finals use 4 officilas.
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.game_officials AS
SELECT DISTINCT        -- DISTINCT removes duplicate assignment rows (source of 5/6-official games)
    GAME_ID::STRING              AS game_id,
    TRY_TO_NUMBER(OFFICIAL_ID)  AS official_id,
    TRIM(FIRST_NAME)             AS first_name,
    TRIM(LAST_NAME)              AS last_name,
    TRY_TO_NUMBER(JERSEY_NUM)   AS jersey_num,
    CURRENT_TIMESTAMP()          AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.OFFICIALS;

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.game_officials;
-- Expected: ~70,971

SELECT COUNT(DISTINCT official_id) AS distinct_officials FROM ZK_NBA.FLAT.game_officials;
-- Expected: ~235

SELECT COUNT(DISTINCT game_id) AS distinct_games FROM ZK_NBA.FLAT.game_officials;
-- Expected: ~23,575
