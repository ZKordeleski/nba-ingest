-- Seed ZK_NBA.FLAT.line_scores from JB_HISTORIC_NBA.PUBLIC.LINE_SCORE.
--
-- LINE_SCORE has 58,053 rows in wide format (home + away in one row).
-- OT columns: JB stores OT1-OT4 as INT and OT5-OT10 as VARCHAR (rare cases).
-- We keep OT1-OT4 only (no known NBA game has gone past 4 OT).
--
-- Note: LINE_SCORE coverage starts in the modern era — check MIN(game_date)
-- after seeding. Pre-modern games in FLAT.games will not have line_score rows.
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- First: inspect the LINE_SCORE schema to confirm column names
-- DESCRIBE TABLE JB_HISTORIC_NBA.PUBLIC.LINE_SCORE;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.line_scores AS
SELECT
    GAME_ID::STRING                      AS game_id,
    GAME_DATE_EST::DATE                  AS game_date,
    TRIM(HOME_TEAM_ABBREVIATION)         AS home_team_abbr,
    TRY_TO_NUMBER(PTS_QTR1_HOME)         AS home_q1,
    TRY_TO_NUMBER(PTS_QTR2_HOME)         AS home_q2,
    TRY_TO_NUMBER(PTS_QTR3_HOME)         AS home_q3,
    TRY_TO_NUMBER(PTS_QTR4_HOME)         AS home_q4,
    TRY_TO_NUMBER(PTS_OT1_HOME)          AS home_ot1,
    TRY_TO_NUMBER(PTS_OT2_HOME)          AS home_ot2,
    TRY_TO_NUMBER(PTS_OT3_HOME)          AS home_ot3,
    TRY_TO_NUMBER(PTS_OT4_HOME)          AS home_ot4,
    TRY_TO_NUMBER(PTS_HOME)              AS home_pts,
    TRIM(VISITOR_TEAM_ABBREVIATION)      AS away_team_abbr,
    TRY_TO_NUMBER(PTS_QTR1_VISITOR)      AS away_q1,
    TRY_TO_NUMBER(PTS_QTR2_VISITOR)      AS away_q2,
    TRY_TO_NUMBER(PTS_QTR3_VISITOR)      AS away_q3,
    TRY_TO_NUMBER(PTS_QTR4_VISITOR)      AS away_q4,
    TRY_TO_NUMBER(PTS_OT1_VISITOR)       AS away_ot1,
    TRY_TO_NUMBER(PTS_OT2_VISITOR)       AS away_ot2,
    TRY_TO_NUMBER(PTS_OT3_VISITOR)       AS away_ot3,
    TRY_TO_NUMBER(PTS_OT4_VISITOR)       AS away_ot4,
    TRY_TO_NUMBER(PTS_VISITOR)           AS away_pts,
    'jb_seed'                            AS source,
    CURRENT_TIMESTAMP()                  AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.LINE_SCORE;

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.line_scores;
-- Expected: ~58,053

SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date FROM ZK_NBA.FLAT.line_scores;
-- Expected: modern era (exact start date TBD — check result)

-- Overtime games sanity check
SELECT COUNT(*) AS overtime_games
FROM ZK_NBA.FLAT.line_scores
WHERE home_ot1 IS NOT NULL;
-- Expected: a few hundred (OT games are uncommon but not rare)
