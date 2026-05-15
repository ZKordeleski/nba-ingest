-- Seed ZK_NBA.FLAT.line_scores from JB_HISTORIC_NBA.PUBLIC.LINE_SCORE.
--
-- Pattern: TRUNCATE + INSERT (preserves DDL comments/PK).
--
-- LINE_SCORE has ~58K rows in wide format (home + away in one row, modern era only).
--
-- COLUMN NAME CORRECTIONS (via DESCRIBE 2026-05-14):
--   - Home team abbr is TEAM_ABBREVIATION_HOME, not HOME_TEAM_ABBREVIATION.
--   - Away team abbr is TEAM_ABBREVIATION_AWAY, not VISITOR_TEAM_ABBREVIATION.
--   - Quarter cols are PTS_QTR1_AWAY (not _VISITOR), and PTS_AWAY (not PTS_VISITOR).
--
-- TYPE MAP:
--   PTS_QTR1-4_HOME/AWAY, PTS_OT1-4_HOME/AWAY, PTS_HOME, PTS_AWAY: NUMBER(38,1) -> ::INT
--   PTS_OT5-10: VARCHAR (rare, ignored — no NBA game has gone past 4 OT).
--
-- DATA QUALITY FIX:
--   JB encodes "no OT period played" inconsistently: ~25,759 games use NULL/NULL,
--   ~29,004 games use 0/0. Real OT count is ~3,290 (matches the NBA's ~6% rate).
--   We normalize: when BOTH home_otN and away_otN are 0, both become NULL.
--   This preserves the 10 unusual cases where one team scored 0 in a real OT.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- DELETE (not TRUNCATE) so BR-scraped rows survive a re-seed. See 001_player_box.sql.
DELETE FROM ZK_NBA.FLAT.line_scores WHERE source = 'jb_seed';

INSERT INTO ZK_NBA.FLAT.line_scores (
    game_id, game_date,
    home_team_abbr, home_q1, home_q2, home_q3, home_q4,
    home_ot1, home_ot2, home_ot3, home_ot4, home_pts,
    away_team_abbr, away_q1, away_q2, away_q3, away_q4,
    away_ot1, away_ot2, away_ot3, away_ot4, away_pts,
    source, fetched_at
)
SELECT
    GAME_ID::STRING                      AS game_id,
    GAME_DATE_EST::DATE                  AS game_date,
    TRIM(TEAM_ABBREVIATION_HOME)         AS home_team_abbr,
    PTS_QTR1_HOME::INT                   AS home_q1,
    PTS_QTR2_HOME::INT                   AS home_q2,
    PTS_QTR3_HOME::INT                   AS home_q3,
    PTS_QTR4_HOME::INT                   AS home_q4,
    CASE WHEN PTS_OT1_HOME = 0 AND PTS_OT1_AWAY = 0 THEN NULL ELSE PTS_OT1_HOME::INT END AS home_ot1,
    CASE WHEN PTS_OT2_HOME = 0 AND PTS_OT2_AWAY = 0 THEN NULL ELSE PTS_OT2_HOME::INT END AS home_ot2,
    CASE WHEN PTS_OT3_HOME = 0 AND PTS_OT3_AWAY = 0 THEN NULL ELSE PTS_OT3_HOME::INT END AS home_ot3,
    CASE WHEN PTS_OT4_HOME = 0 AND PTS_OT4_AWAY = 0 THEN NULL ELSE PTS_OT4_HOME::INT END AS home_ot4,
    PTS_HOME::INT                        AS home_pts,
    TRIM(TEAM_ABBREVIATION_AWAY)         AS away_team_abbr,
    PTS_QTR1_AWAY::INT                   AS away_q1,
    PTS_QTR2_AWAY::INT                   AS away_q2,
    PTS_QTR3_AWAY::INT                   AS away_q3,
    PTS_QTR4_AWAY::INT                   AS away_q4,
    CASE WHEN PTS_OT1_HOME = 0 AND PTS_OT1_AWAY = 0 THEN NULL ELSE PTS_OT1_AWAY::INT END AS away_ot1,
    CASE WHEN PTS_OT2_HOME = 0 AND PTS_OT2_AWAY = 0 THEN NULL ELSE PTS_OT2_AWAY::INT END AS away_ot2,
    CASE WHEN PTS_OT3_HOME = 0 AND PTS_OT3_AWAY = 0 THEN NULL ELSE PTS_OT3_AWAY::INT END AS away_ot3,
    CASE WHEN PTS_OT4_HOME = 0 AND PTS_OT4_AWAY = 0 THEN NULL ELSE PTS_OT4_AWAY::INT END AS away_ot4,
    PTS_AWAY::INT                        AS away_pts,
    'jb_seed'                            AS source,
    CURRENT_TIMESTAMP()                  AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.LINE_SCORE;

SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.line_scores;
SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date FROM ZK_NBA.FLAT.line_scores;
SELECT COUNT(*) AS overtime_games FROM ZK_NBA.FLAT.line_scores WHERE home_ot1 IS NOT NULL;
