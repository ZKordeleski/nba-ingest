-- Slice 1 validation: date ranges.
-- Run after all 050_seed_from_jb/*.sql files have completed.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- Games: full history from first NBA game to end of 2022-23 Finals
SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date
FROM ZK_NBA.FLAT.games;
-- Expected: 1946-11-01 to 2023-06-12

-- Player box: full history (JB1 + JB2 union)
SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date
FROM ZK_NBA.FLAT.player_box_basic;
-- Expected: 1946-11-26 to 2025-04-06

-- Line scores: modern era
SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date
FROM ZK_NBA.FLAT.line_scores;
-- Expected: modern era start (exact date TBD — check result)

-- Draft: 1947 to 2023
SELECT MIN(season) AS min_season, MAX(season) AS max_season
FROM ZK_NBA.FLAT.draft;
-- Expected: 1947 to 2023

-- Draft combine: when does it start?
SELECT MIN(season) AS min_season, MAX(season) AS max_season
FROM ZK_NBA.FLAT.draft_combine;
-- Expected: ~2000 to 2022 or similar (combine started ~2000)

-- PBP: modern games only
SELECT COUNT(DISTINCT game_id) AS game_count,
       MIN(g.game_date) AS min_date,
       MAX(g.game_date) AS max_date
FROM ZK_NBA.FLAT.play_by_play pbp
JOIN ZK_NBA.FLAT.games g ON pbp.game_id = g.game_id;
-- Expected: ~5,337 games, modern era dates

-- Gap check: are there any seasons missing from player_box_basic?
SELECT
    YEAR(game_date) AS cal_year,
    COUNT(*) AS box_rows
FROM ZK_NBA.FLAT.player_box_basic
GROUP BY 1
ORDER BY 1;
-- Expected: rows for every year 1946 through 2025 (some years may be thin
-- for early seasons with fewer players and shorter schedules)
