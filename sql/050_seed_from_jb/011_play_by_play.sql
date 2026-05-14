-- Seed ZK_NBA.FLAT.play_by_play from JB_HISTORIC_NBA.PUBLIC.PLAY_BY_PLAY_PART001
-- and JB_HISTORIC_NBA.PUBLIC.PLAY_BY_PLAY_PART002.
--
-- PLAY_BY_PLAY_PART001: 1,208,387 rows, 2,678 distinct games
-- PLAY_BY_PLAY_PART002: 1,208,387 rows, 2,660 distinct games
-- 1 game appears in both parts — UNION (not UNION ALL) deduplicates.
-- Total expected: ~2,416,773 rows (both parts minus duplicate game's events).
--
-- Both parts have identical 34-column schemas.
-- Coverage: modern games only (~5,300 games total across both parts).
--
-- WARNING: This query processes ~2.4M rows. Expect 1-3 min on XSMALL.
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.play_by_play AS
WITH combined AS (
    SELECT
        GAME_ID::STRING                AS game_id,
        TRY_TO_NUMBER(EVENTNUM)        AS event_num,
        TRY_TO_NUMBER(EVENTMSGTYPE)    AS event_type,
        TRY_TO_NUMBER(EVENTMSGACTIONTYPE) AS event_action_type,
        TRY_TO_NUMBER(PERIOD)          AS period,
        TRIM(WCTIMESTRING)             AS clock_wall,
        TRIM(PCTIMESTRING)             AS clock_game,
        TRIM(HOMEDESCRIPTION)          AS home_description,
        TRIM(VISITORDESCRIPTION)       AS visitor_description,
        TRIM(NEUTRALDESCRIPTION)       AS neutral_description,
        TRIM(SCORE)                    AS score,
        TRIM(SCOREMARGIN)              AS score_margin,
        TRY_TO_NUMBER(PLAYER1_ID)      AS player1_id,
        TRIM(PLAYER1_NAME)             AS player1_name,
        TRIM(PLAYER1_TEAM_ABBREVIATION) AS player1_team_abbr,
        TRY_TO_NUMBER(PLAYER2_ID)      AS player2_id,
        TRIM(PLAYER2_NAME)             AS player2_name,
        TRIM(PLAYER2_TEAM_ABBREVIATION) AS player2_team_abbr,
        TRY_TO_NUMBER(PLAYER3_ID)      AS player3_id,
        TRIM(PLAYER3_NAME)             AS player3_name,
        TRIM(PLAYER3_TEAM_ABBREVIATION) AS player3_team_abbr,
        CURRENT_TIMESTAMP()            AS fetched_at
    FROM JB_HISTORIC_NBA.PUBLIC.PLAY_BY_PLAY_PART001

    UNION  -- NOT UNION ALL: deduplicates the 1 game that appears in both parts

    SELECT
        GAME_ID::STRING                AS game_id,
        TRY_TO_NUMBER(EVENTNUM)        AS event_num,
        TRY_TO_NUMBER(EVENTMSGTYPE)    AS event_type,
        TRY_TO_NUMBER(EVENTMSGACTIONTYPE) AS event_action_type,
        TRY_TO_NUMBER(PERIOD)          AS period,
        TRIM(WCTIMESTRING)             AS clock_wall,
        TRIM(PCTIMESTRING)             AS clock_game,
        TRIM(HOMEDESCRIPTION)          AS home_description,
        TRIM(VISITORDESCRIPTION)       AS visitor_description,
        TRIM(NEUTRALDESCRIPTION)       AS neutral_description,
        TRIM(SCORE)                    AS score,
        TRIM(SCOREMARGIN)              AS score_margin,
        TRY_TO_NUMBER(PLAYER1_ID)      AS player1_id,
        TRIM(PLAYER1_NAME)             AS player1_name,
        TRIM(PLAYER1_TEAM_ABBREVIATION) AS player1_team_abbr,
        TRY_TO_NUMBER(PLAYER2_ID)      AS player2_id,
        TRIM(PLAYER2_NAME)             AS player2_name,
        TRIM(PLAYER2_TEAM_ABBREVIATION) AS player2_team_abbr,
        TRY_TO_NUMBER(PLAYER3_ID)      AS player3_id,
        TRIM(PLAYER3_NAME)             AS player3_name,
        TRIM(PLAYER3_TEAM_ABBREVIATION) AS player3_team_abbr,
        CURRENT_TIMESTAMP()            AS fetched_at
    FROM JB_HISTORIC_NBA.PUBLIC.PLAY_BY_PLAY_PART002
)
SELECT * FROM combined;

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.play_by_play;
-- Expected: ~2,416,773 (2*1,208,387 minus duplicate game's ~800 events)

SELECT COUNT(DISTINCT game_id) AS distinct_games FROM ZK_NBA.FLAT.play_by_play;
-- Expected: ~5,337 (2,678 + 2,660 - 1 duplicate = 5,337)

-- Spot check: event types present
SELECT event_type, COUNT(*) AS n
FROM ZK_NBA.FLAT.play_by_play
GROUP BY event_type
ORDER BY n DESC
LIMIT 10;
-- Expected: event_type 1 (made shot) should be among the top
