-- Seed ZK_NBA.FLAT.games from JB_HISTORIC_NBA.PUBLIC.GAME.
--
-- The GAME table has 65,642 rows covering 1946-Jun 2023.
-- It is already in wide format (1 row per game, both teams' stats inline).
-- Our FLAT.games table preserves this grain — no pivoting required.
--
-- Type casting is critical here: many numeric columns in JB's GAME table are stored
-- as VARCHAR (STL_HOME, BLK_HOME, TOV_HOME, etc.). Use TRY_TO_NUMBER() / TRY_TO_DECIMAL()
-- to cast safely — a failed cast returns NULL rather than erroring.
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- PRE-SEED VALIDATION FINDINGS (run against JB source 2026-05-11):
--   - 65,698 total rows, 65,642 distinct GAME_IDs = 56 duplicate game_ids.
--   - Duplicates are early-era games (1930s-1940s season_ids).
--   - All VARCHAR stat columns (STL_HOME, BLK_HOME, etc.) are actually numeric —
--     0 non-numeric values found; TRY_TO_NUMBER() casts cleanly.
--   - No null GAME_ID, GAME_DATE, PTS_HOME, or SEASON_TYPE.
--   - Deduplication strategy: take first row per GAME_ID by GAME_DATE DESC.

CREATE OR REPLACE TABLE ZK_NBA.FLAT.games AS
WITH deduped AS (
    -- Remove 56 duplicate GAME_IDs found in JB source (early-era load artifacts)
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY GAME_ID ORDER BY GAME_DATE DESC) AS rn
    FROM JB_HISTORIC_NBA.PUBLIC.GAME
)
SELECT
    GAME_ID::STRING                            AS game_id,
    GAME_DATE::DATE                            AS game_date,
    -- Season end year: SEASON_ID format is 2YYYY for regular season (e.g. 22022 = 2022-23)
    -- The last 4 digits are the season start year; add 1 for season end year.
    TRY_TO_NUMBER(RIGHT(SEASON_ID::STRING, 4)) + 1 AS season,
    TRY_TO_NUMBER(SEASON_ID::STRING)           AS season_id,
    TRIM(SEASON_TYPE)                          AS season_type,
    TRY_TO_NUMBER(TEAM_ID_HOME)                AS home_team_id,
    TRIM(TEAM_ABBREVIATION_HOME)               AS home_team_abbr,
    TRY_TO_NUMBER(TEAM_ID_AWAY)                AS away_team_id,
    TRIM(TEAM_ABBREVIATION_AWAY)               AS away_team_abbr,
    TRY_TO_NUMBER(PTS_HOME)                    AS home_pts,
    TRY_TO_NUMBER(PTS_AWAY)                    AS away_pts,
    TRIM(WL_HOME)                              AS home_wl,
    TRY_TO_NUMBER(FGM_HOME)                    AS home_fgm,
    TRY_TO_NUMBER(FGA_HOME)                    AS home_fga,
    TRY_TO_DECIMAL(FG_PCT_HOME, 10, 4)         AS home_fg_pct,
    TRY_TO_NUMBER(FG3M_HOME)                   AS home_fg3m,
    TRY_TO_NUMBER(FG3A_HOME)                   AS home_fg3a,
    TRY_TO_DECIMAL(FG3_PCT_HOME, 10, 4)        AS home_fg3_pct,
    TRY_TO_NUMBER(FTM_HOME)                    AS home_ftm,
    TRY_TO_NUMBER(FTA_HOME)                    AS home_fta,
    TRY_TO_DECIMAL(FT_PCT_HOME, 10, 4)         AS home_ft_pct,
    TRY_TO_NUMBER(OREB_HOME)                   AS home_oreb,
    TRY_TO_NUMBER(DREB_HOME)                   AS home_dreb,
    TRY_TO_NUMBER(REB_HOME)                    AS home_reb,
    TRY_TO_NUMBER(AST_HOME)                    AS home_ast,
    TRY_TO_NUMBER(STL_HOME)                    AS home_stl,
    TRY_TO_NUMBER(BLK_HOME)                    AS home_blk,
    TRY_TO_NUMBER(TOV_HOME)                    AS home_tov,
    TRY_TO_NUMBER(PF_HOME)                     AS home_pf,
    TRY_TO_NUMBER(PLUS_MINUS_HOME)             AS home_plus_minus,
    TRY_TO_NUMBER(FGM_AWAY)                    AS away_fgm,
    TRY_TO_NUMBER(FGA_AWAY)                    AS away_fga,
    TRY_TO_DECIMAL(FG_PCT_AWAY, 10, 4)         AS away_fg_pct,
    TRY_TO_NUMBER(FG3M_AWAY)                   AS away_fg3m,
    TRY_TO_NUMBER(FG3A_AWAY)                   AS away_fg3a,
    TRY_TO_DECIMAL(FG3_PCT_AWAY, 10, 4)        AS away_fg3_pct,
    TRY_TO_NUMBER(FTM_AWAY)                    AS away_ftm,
    TRY_TO_NUMBER(FTA_AWAY)                    AS away_fta,
    TRY_TO_DECIMAL(FT_PCT_AWAY, 10, 4)         AS away_ft_pct,
    TRY_TO_NUMBER(OREB_AWAY)                   AS away_oreb,
    TRY_TO_NUMBER(DREB_AWAY)                   AS away_dreb,
    TRY_TO_NUMBER(REB_AWAY)                    AS away_reb,
    TRY_TO_NUMBER(AST_AWAY)                    AS away_ast,
    TRY_TO_NUMBER(STL_AWAY)                    AS away_stl,
    TRY_TO_NUMBER(BLK_AWAY)                    AS away_blk,
    TRY_TO_NUMBER(TOV_AWAY)                    AS away_tov,
    TRY_TO_NUMBER(PF_AWAY)                     AS away_pf,
    TRY_TO_NUMBER(PLUS_MINUS_AWAY)             AS away_plus_minus,
    'jb_seed'                                  AS source,
    CURRENT_TIMESTAMP()                        AS fetched_at
FROM deduped
WHERE rn = 1;  -- Take one row per GAME_ID; eliminates 56 duplicates

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.games;
-- Expected: ~65,642 (deduplication removed 56 extra rows from 65,698 source rows)

SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date FROM ZK_NBA.FLAT.games;
-- Expected: 1946-11-01 to 2023-06-12

-- Spot-check cast quality (should be 0 nulls on pts for any completed game)
SELECT COUNT(*) AS null_home_pts FROM ZK_NBA.FLAT.games WHERE home_pts IS NULL;
-- Expected: 0 (all games in JB have scores)
