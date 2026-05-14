-- Seed ZK_NBA.FLAT.play_by_play from JB PLAY_BY_PLAY_PART001/002.
--
-- Pattern: TRUNCATE + INSERT (preserves DDL comments/PK).
--
-- PLAY_BY_PLAY_PART001: ~1.2M rows, ~2,678 distinct games
-- PLAY_BY_PLAY_PART002: ~1.2M rows, ~2,660 distinct games
-- 1 game appears in both — UNION (not UNION ALL) deduplicates row-for-row.
--
-- TYPE NOTES (via DESCRIBE 2026-05-14):
--   - GAME_ID, EVENTNUM, EVENT*, PERIOD, PLAYER*_ID: NUMBER(38,0).
--   - PCTIMESTRING: TIME(9) (!) — represents game clock as a TIME. TO_VARCHAR
--     gives the "HH:MM:SS" form (e.g., 11:34:00). We keep TIME format as-is for
--     fidelity; analysis tier can compute remaining-time as needed.
--   - SCORE, SCOREMARGIN, descriptions: VARCHAR.
--
-- WARNING: ~2.4M rows. Expect 1-3 min on XSMALL warehouse.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

TRUNCATE TABLE ZK_NBA.FLAT.play_by_play;

INSERT INTO ZK_NBA.FLAT.play_by_play (
    game_id, event_num, event_type, event_action_type, period,
    clock_wall, clock_game,
    home_description, visitor_description, neutral_description,
    score, score_margin,
    player1_id, player1_name, player1_team_abbr,
    player2_id, player2_name, player2_team_abbr,
    player3_id, player3_name, player3_team_abbr,
    fetched_at
)
WITH combined AS (
    SELECT
        GAME_ID::STRING                AS game_id,
        EVENTNUM::INT                  AS event_num,
        EVENTMSGTYPE::INT              AS event_type,
        EVENTMSGACTIONTYPE::INT        AS event_action_type,
        PERIOD::INT                    AS period,
        TRIM(WCTIMESTRING)             AS clock_wall,
        TO_VARCHAR(PCTIMESTRING)       AS clock_game,
        TRIM(HOMEDESCRIPTION)          AS home_description,
        TRIM(VISITORDESCRIPTION)       AS visitor_description,
        TRIM(NEUTRALDESCRIPTION)       AS neutral_description,
        TRIM(SCORE)                    AS score,
        TRIM(SCOREMARGIN)              AS score_margin,
        PLAYER1_ID::INT                AS player1_id,
        TRIM(PLAYER1_NAME)             AS player1_name,
        TRIM(PLAYER1_TEAM_ABBREVIATION) AS player1_team_abbr,
        PLAYER2_ID::INT                AS player2_id,
        TRIM(PLAYER2_NAME)             AS player2_name,
        TRIM(PLAYER2_TEAM_ABBREVIATION) AS player2_team_abbr,
        PLAYER3_ID::INT                AS player3_id,
        TRIM(PLAYER3_NAME)             AS player3_name,
        TRIM(PLAYER3_TEAM_ABBREVIATION) AS player3_team_abbr,
        CURRENT_TIMESTAMP()            AS fetched_at
    FROM JB_HISTORIC_NBA.PUBLIC.PLAY_BY_PLAY_PART001

    UNION

    SELECT
        GAME_ID::STRING                AS game_id,
        EVENTNUM::INT                  AS event_num,
        EVENTMSGTYPE::INT              AS event_type,
        EVENTMSGACTIONTYPE::INT        AS event_action_type,
        PERIOD::INT                    AS period,
        TRIM(WCTIMESTRING)             AS clock_wall,
        TO_VARCHAR(PCTIMESTRING)       AS clock_game,
        TRIM(HOMEDESCRIPTION)          AS home_description,
        TRIM(VISITORDESCRIPTION)       AS visitor_description,
        TRIM(NEUTRALDESCRIPTION)       AS neutral_description,
        TRIM(SCORE)                    AS score,
        TRIM(SCOREMARGIN)              AS score_margin,
        PLAYER1_ID::INT                AS player1_id,
        TRIM(PLAYER1_NAME)             AS player1_name,
        TRIM(PLAYER1_TEAM_ABBREVIATION) AS player1_team_abbr,
        PLAYER2_ID::INT                AS player2_id,
        TRIM(PLAYER2_NAME)             AS player2_name,
        TRIM(PLAYER2_TEAM_ABBREVIATION) AS player2_team_abbr,
        PLAYER3_ID::INT                AS player3_id,
        TRIM(PLAYER3_NAME)             AS player3_name,
        TRIM(PLAYER3_TEAM_ABBREVIATION) AS player3_team_abbr,
        CURRENT_TIMESTAMP()            AS fetched_at
    FROM JB_HISTORIC_NBA.PUBLIC.PLAY_BY_PLAY_PART002
)
SELECT * FROM combined;

SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.play_by_play;
SELECT COUNT(DISTINCT game_id) AS distinct_games FROM ZK_NBA.FLAT.play_by_play;

SELECT event_type, COUNT(*) AS n
FROM ZK_NBA.FLAT.play_by_play
GROUP BY event_type ORDER BY n DESC LIMIT 10;
