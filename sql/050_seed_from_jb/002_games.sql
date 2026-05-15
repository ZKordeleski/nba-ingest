-- Seed ZK_NBA.FLAT.games from JB_HISTORIC_NBA.PUBLIC.GAME.
--
-- Pattern: TRUNCATE + INSERT (preserves typed schema, comments, PK from
-- 040_flat_tables.sql).
--
-- GAME has ~65,698 rows covering 1946 through Jun 2023, already in wide format.
-- 56 duplicate GAME_IDs in early-era games; deduplicated by row_number.
--
-- TYPE MAP (via DESCRIBE 2026-05-14):
--   NUMBER(38,1) stat cols (need ::INT):
--     FGM_HOME, FGA_HOME, FTM_HOME, FTA_HOME, REB_HOME, AST_HOME, PF_HOME,
--     PTS_HOME, and _AWAY equivalents.
--   NUMBER(38,0) cols (TRY_TO_NUMBER or direct cast both fine):
--     TEAM_ID_HOME/AWAY, FG3M, FG3A, PLUS_MINUS, SEASON_ID.
--   NUMBER(38,3) pct cols (need ::FLOAT):
--     FG_PCT_HOME, FT_PCT_HOME, and _AWAY.
--   VARCHAR cols (numeric-content, TRY_TO_NUMBER fine):
--     FG3_PCT_HOME, OREB_HOME, DREB_HOME, STL_HOME, BLK_HOME, TOV_HOME,
--     and _AWAY equivalents.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- DELETE (not TRUNCATE) so BR-scraped rows survive a re-seed. See 001_player_box.sql
-- for the full rationale — same TRUNCATE footgun applies to any table written by
-- both pipelines.
DELETE FROM ZK_NBA.FLAT.games WHERE source = 'jb_seed';

INSERT INTO ZK_NBA.FLAT.games (
    game_id, game_date, season, season_id, season_type,
    home_team_id, home_team_abbr, away_team_id, away_team_abbr,
    home_pts, away_pts, home_wl,
    home_fgm, home_fga, home_fg_pct, home_fg3m, home_fg3a, home_fg3_pct,
    home_ftm, home_fta, home_ft_pct,
    home_oreb, home_dreb, home_reb, home_ast, home_stl, home_blk,
    home_tov, home_pf, home_plus_minus,
    away_fgm, away_fga, away_fg_pct, away_fg3m, away_fg3a, away_fg3_pct,
    away_ftm, away_fta, away_ft_pct,
    away_oreb, away_dreb, away_reb, away_ast, away_stl, away_blk,
    away_tov, away_pf, away_plus_minus,
    source, fetched_at
)
WITH deduped AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY GAME_ID ORDER BY GAME_DATE DESC) AS rn
    FROM JB_HISTORIC_NBA.PUBLIC.GAME
)
SELECT
    GAME_ID::STRING                            AS game_id,
    GAME_DATE::DATE                            AS game_date,
    -- SEASON_ID format: 2YYYY = regular season starting in YYYY (e.g. 22022 = 2022-23).
    -- season end year = start year + 1.
    TRY_TO_NUMBER(RIGHT(SEASON_ID::STRING, 4)) + 1 AS season,
    SEASON_ID::INT                             AS season_id,
    TRIM(SEASON_TYPE)                          AS season_type,
    TEAM_ID_HOME::INT                          AS home_team_id,
    TRIM(TEAM_ABBREVIATION_HOME)               AS home_team_abbr,
    TEAM_ID_AWAY::INT                          AS away_team_id,
    TRIM(TEAM_ABBREVIATION_AWAY)               AS away_team_abbr,
    PTS_HOME::INT                              AS home_pts,
    PTS_AWAY::INT                              AS away_pts,
    TRIM(WL_HOME)                              AS home_wl,
    FGM_HOME::INT                              AS home_fgm,
    FGA_HOME::INT                              AS home_fga,
    FG_PCT_HOME::FLOAT                         AS home_fg_pct,
    FG3M_HOME::INT                             AS home_fg3m,
    FG3A_HOME::INT                             AS home_fg3a,
    TRY_TO_DECIMAL(FG3_PCT_HOME, 10, 4)::FLOAT AS home_fg3_pct,
    FTM_HOME::INT                              AS home_ftm,
    FTA_HOME::INT                              AS home_fta,
    FT_PCT_HOME::FLOAT                         AS home_ft_pct,
    TRY_TO_NUMBER(OREB_HOME)                   AS home_oreb,
    TRY_TO_NUMBER(DREB_HOME)                   AS home_dreb,
    REB_HOME::INT                              AS home_reb,
    AST_HOME::INT                              AS home_ast,
    TRY_TO_NUMBER(STL_HOME)                    AS home_stl,
    TRY_TO_NUMBER(BLK_HOME)                    AS home_blk,
    TRY_TO_NUMBER(TOV_HOME)                    AS home_tov,
    PF_HOME::INT                               AS home_pf,
    PLUS_MINUS_HOME::INT                       AS home_plus_minus,
    FGM_AWAY::INT                              AS away_fgm,
    FGA_AWAY::INT                              AS away_fga,
    FG_PCT_AWAY::FLOAT                         AS away_fg_pct,
    FG3M_AWAY::INT                             AS away_fg3m,
    FG3A_AWAY::INT                             AS away_fg3a,
    TRY_TO_DECIMAL(FG3_PCT_AWAY, 10, 4)::FLOAT AS away_fg3_pct,
    FTM_AWAY::INT                              AS away_ftm,
    FTA_AWAY::INT                              AS away_fta,
    FT_PCT_AWAY::FLOAT                         AS away_ft_pct,
    TRY_TO_NUMBER(OREB_AWAY)                   AS away_oreb,
    TRY_TO_NUMBER(DREB_AWAY)                   AS away_dreb,
    REB_AWAY::INT                              AS away_reb,
    AST_AWAY::INT                              AS away_ast,
    TRY_TO_NUMBER(STL_AWAY)                    AS away_stl,
    TRY_TO_NUMBER(BLK_AWAY)                    AS away_blk,
    TRY_TO_NUMBER(TOV_AWAY)                    AS away_tov,
    PF_AWAY::INT                               AS away_pf,
    PLUS_MINUS_AWAY::INT                       AS away_plus_minus,
    'jb_seed'                                  AS source,
    CURRENT_TIMESTAMP()                        AS fetched_at
FROM deduped
WHERE rn = 1;

SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.games;
SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date FROM ZK_NBA.FLAT.games;
SELECT COUNT(*) AS null_home_pts FROM ZK_NBA.FLAT.games WHERE home_pts IS NULL;
