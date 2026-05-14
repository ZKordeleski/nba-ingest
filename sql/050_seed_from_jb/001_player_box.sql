-- Seed ZK_NBA.FLAT.player_box_basic from JB_HISTORIC_NBA.PUBLIC.
--
-- PLAYERSTATISTICS1 covers 2001-12-30 to 2025-04-06 (811,672 rows total).
-- PLAYERSTATISTICS2 covers 1946-11-26 to 2001-12-30 (811,671 rows total).
-- Combined with UNION: ~1,623,343 rows before filtering.
--
-- PRE-SEED VALIDATION FINDINGS (run against JB source 2026-05-11):
--   - PS1 includes 54,580 Preseason rows — excluded here (not real games).
--   - PS1/PS2 boundary (2001-12-30) has ZERO overlapping (GAMEID,PERSONID) pairs — UNION is safe.
--   - 1,219 rows have NULL POINTS; 137,419 have NULL MINUTES. These are DNP
--     (Did Not Play) entries — included with 0 for stats, NULL for minutes.
--   - WIN column is a NUMBER (1=win, 0=loss), not VARCHAR. Fixed below.
--   - No negative point values; no null GAMEID or PERSONID.
--
-- Included game types: Regular Season, Playoffs, Play-in Tournament, NBA Cup,
--   NBA Emirates Cup. Excluded: Preseason.
--
-- Run after 040_flat_tables.sql. Takes ~30-60s on NBA_INGEST_WH (XSMALL).

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.player_box_basic AS
WITH combined AS (
    -- Modern player stats: 2001-12-30 to 2025-04-06
    SELECT
        GAMEID::STRING                               AS game_id,
        PERSONID::STRING                             AS player_id,
        TRIM(FIRSTNAME) || ' ' || TRIM(LASTNAME)    AS player_name,
        NULL::INT                                    AS team_id,
        TRIM(PLAYERTEAMCITY) || ' ' || TRIM(PLAYERTEAMNAME) AS team_name,
        NULL::STRING                                 AS team_abbr,
        TRIM(OPPONENTTEAMCITY) || ' ' || TRIM(OPPONENTTEAMNAME) AS opponent_team_name,
        GAMEDATE::DATE                               AS game_date,
        NULL::INT                                    AS season,
        TRIM(GAMETYPE)                               AS game_type,
        CASE WHEN WIN = 1 THEN TRUE ELSE FALSE END   AS is_win,   -- WIN is NUMBER, not VARCHAR
        CASE WHEN HOME = 1 THEN TRUE ELSE FALSE END  AS is_home,
        TRY_TO_DOUBLE(NUMMINUTES)                    AS minutes_played,  -- NULL = DNP
        COALESCE(TRY_TO_NUMBER(POINTS), 0)           AS pts,
        COALESCE(TRY_TO_NUMBER(ASSISTS), 0)          AS ast,
        COALESCE(TRY_TO_NUMBER(REBOUNDSTOTAL), 0)    AS reb,
        COALESCE(TRY_TO_NUMBER(REBOUNDSOFFENSIVE), 0) AS oreb,
        COALESCE(TRY_TO_NUMBER(REBOUNDSDEFENSIVE), 0) AS dreb,
        COALESCE(TRY_TO_NUMBER(STEALS), 0)           AS stl,
        COALESCE(TRY_TO_NUMBER(BLOCKS), 0)           AS blk,
        COALESCE(TRY_TO_NUMBER(TURNOVERS), 0)        AS tov,
        COALESCE(TRY_TO_NUMBER(FOULSPERSONAL), 0)    AS pf,
        COALESCE(TRY_TO_NUMBER(FIELDGOALSMADE), 0)   AS fgm,
        COALESCE(TRY_TO_NUMBER(FIELDGOALSATTEMPTED), 0) AS fga,
        TRY_TO_DECIMAL(FIELDGOALSPERCENTAGE, 10, 4)  AS fg_pct,
        COALESCE(TRY_TO_NUMBER(THREEPOINTERSMADE), 0) AS fg3m,
        COALESCE(TRY_TO_NUMBER(THREEPOINTERSATTEMPTED), 0) AS fg3a,
        TRY_TO_DECIMAL(THREEPOINTERSPERCENTAGE, 10, 4) AS fg3_pct,
        COALESCE(TRY_TO_NUMBER(FREETHROWSMADE), 0)   AS ftm,
        COALESCE(TRY_TO_NUMBER(FREETHROWSATTEMPTED), 0) AS fta,
        TRY_TO_DECIMAL(FREETHROWSPERCENTAGE, 10, 4)  AS ft_pct,
        TRY_TO_DOUBLE(PLUSMINUSPOINTS)               AS plus_minus,
        'jb_seed'                                    AS source,
        CURRENT_TIMESTAMP()                          AS fetched_at
    FROM JB_HISTORIC_NBA.PUBLIC.PLAYERSTATISTICS1
    WHERE GAMETYPE != 'Preseason'  -- 54,580 rows excluded; not real games

    UNION

    -- Historical player stats: 1946-11-26 to 2001-12-30
    SELECT
        GAMEID::STRING                               AS game_id,
        PERSONID::STRING                             AS player_id,
        TRIM(FIRSTNAME) || ' ' || TRIM(LASTNAME)    AS player_name,
        NULL::INT                                    AS team_id,
        TRIM(PLAYERTEAMCITY) || ' ' || TRIM(PLAYERTEAMNAME) AS team_name,
        NULL::STRING                                 AS team_abbr,
        TRIM(OPPONENTTEAMCITY) || ' ' || TRIM(OPPONENTTEAMNAME) AS opponent_team_name,
        GAMEDATE::DATE                               AS game_date,
        NULL::INT                                    AS season,
        TRIM(GAMETYPE)                               AS game_type,
        CASE WHEN WIN = 1 THEN TRUE ELSE FALSE END   AS is_win,
        CASE WHEN HOME = 1 THEN TRUE ELSE FALSE END  AS is_home,
        TRY_TO_DOUBLE(NUMMINUTES)                    AS minutes_played,
        COALESCE(TRY_TO_NUMBER(POINTS), 0)           AS pts,
        COALESCE(TRY_TO_NUMBER(ASSISTS), 0)          AS ast,
        COALESCE(TRY_TO_NUMBER(REBOUNDSTOTAL), 0)    AS reb,
        COALESCE(TRY_TO_NUMBER(REBOUNDSOFFENSIVE), 0) AS oreb,
        COALESCE(TRY_TO_NUMBER(REBOUNDSDEFENSIVE), 0) AS dreb,
        COALESCE(TRY_TO_NUMBER(STEALS), 0)           AS stl,
        COALESCE(TRY_TO_NUMBER(BLOCKS), 0)           AS blk,
        COALESCE(TRY_TO_NUMBER(TURNOVERS), 0)        AS tov,
        COALESCE(TRY_TO_NUMBER(FOULSPERSONAL), 0)    AS pf,
        COALESCE(TRY_TO_NUMBER(FIELDGOALSMADE), 0)   AS fgm,
        COALESCE(TRY_TO_NUMBER(FIELDGOALSATTEMPTED), 0) AS fga,
        TRY_TO_DECIMAL(FIELDGOALSPERCENTAGE, 10, 4)  AS fg_pct,
        COALESCE(TRY_TO_NUMBER(THREEPOINTERSMADE), 0) AS fg3m,
        COALESCE(TRY_TO_NUMBER(THREEPOINTERSATTEMPTED), 0) AS fg3a,
        TRY_TO_DECIMAL(THREEPOINTERSPERCENTAGE, 10, 4) AS fg3_pct,
        COALESCE(TRY_TO_NUMBER(FREETHROWSMADE), 0)   AS ftm,
        COALESCE(TRY_TO_NUMBER(FREETHROWSATTEMPTED), 0) AS fta,
        TRY_TO_DECIMAL(FREETHROWSPERCENTAGE, 10, 4)  AS ft_pct,
        TRY_TO_DOUBLE(PLUSMINUSPOINTS)               AS plus_minus,
        'jb_seed'                                    AS source,
        CURRENT_TIMESTAMP()                          AS fetched_at
    FROM JB_HISTORIC_NBA.PUBLIC.PLAYERSTATISTICS2
    -- PLAYERSTATISTICS2 predates the Preseason/game-type split; no filter needed.
    -- Historical data is all Regular Season + Playoffs.
)
SELECT * FROM combined;

-- Verify row count (Preseason excluded)
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.player_box_basic;
-- Expected: ~1,568,763 (1,623,343 minus ~54,580 preseason rows)

SELECT game_type, COUNT(*) AS n FROM ZK_NBA.FLAT.player_box_basic
GROUP BY game_type ORDER BY n DESC;
-- Expected: Regular Season >> Playoffs > Play-in > NBA Cup/Emirates Cup
-- Preseason should NOT appear here

SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date
FROM ZK_NBA.FLAT.player_box_basic;
-- Expected: 1946-11-26 to 2025-04-06

-- Spot check: Jokic in 2023 Finals Game 5 (validated against JB source 2026-05-11)
SELECT player_name, pts, ast, reb, fgm, fga, fg3m, fg3a, ftm, fta, plus_minus
FROM ZK_NBA.FLAT.player_box_basic
WHERE game_id = '42200405' AND player_name ILIKE '%Jokic%';
-- Expected: pts=28, ast=4, reb=16, fgm=12, fga=16, fg3m=1, fg3a=3, ftm=3, fta=5, plus_minus=12
