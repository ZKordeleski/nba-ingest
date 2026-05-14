-- Seed ZK_NBA.FLAT.player_box_basic from JB_HISTORIC_NBA.PUBLIC.
--
-- Pattern: TRUNCATE + INSERT (not CREATE OR REPLACE TABLE AS SELECT) so that
-- the typed schema, column comments, and PK constraints from 040_flat_tables.sql
-- remain intact. INSERT also strict-type-checks each column against the DDL.
--
-- PLAYERSTATISTICS1 covers 2001-12-30 to 2025-04-06 (~811K rows).
-- PLAYERSTATISTICS2 covers 1946-11-26 to 2001-12-30 (~811K rows).
-- Combined with UNION (deduplicates identical rows): ~1.6M rows before filtering.
--
-- PRE-SEED VALIDATION FINDINGS (against JB source 2026-05-11):
--   - PS1 includes 54,580 Preseason rows — excluded here (not real games).
--   - PS1/PS2 boundary (2001-12-30) has ZERO overlapping (GAMEID,PERSONID) pairs.
--   - 1,219 rows have NULL POINTS; 137,419 have NULL MINUTES. DNP entries:
--     COALESCE counting stats to 0; minutes_played stays NULL.
--   - WIN/HOME are NUMBER(38,0); 1=true, 0=false.
--
-- TYPE MAP (discovered via DESCRIBE 2026-05-14):
--   - Stat cols in PS1/PS2 are NUMBER(38,1); ::INT permits truncation
--     (TRY_TO_NUMBER refuses NUMBER(38,1) -> NUMBER(38,0)).
--   - PCT cols differ in scale between PS1 (NUMBER(38,15)) and PS2
--     (NUMBER(38,3)) — explicit ::FLOAT on both branches keeps UNION clean.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

TRUNCATE TABLE ZK_NBA.FLAT.player_box_basic;

INSERT INTO ZK_NBA.FLAT.player_box_basic (
    game_id, player_id, player_name, team_id, team_name, team_abbr,
    opponent_team_name, game_date, season, game_type, is_win, is_home,
    minutes_played, pts, ast, reb, oreb, dreb, stl, blk, tov, pf,
    fgm, fga, fg_pct, fg3m, fg3a, fg3_pct, ftm, fta, ft_pct,
    plus_minus, source, fetched_at
)
WITH combined AS (
    SELECT
        GAMEID::STRING                                       AS game_id,
        PERSONID::STRING                                     AS player_id,
        TRIM(FIRSTNAME) || ' ' || TRIM(LASTNAME)             AS player_name,
        NULL::INT                                            AS team_id,
        TRIM(PLAYERTEAMCITY) || ' ' || TRIM(PLAYERTEAMNAME)  AS team_name,
        NULL::STRING                                         AS team_abbr,
        TRIM(OPPONENTTEAMCITY) || ' ' || TRIM(OPPONENTTEAMNAME) AS opponent_team_name,
        GAMEDATE::DATE                                       AS game_date,
        NULL::INT                                            AS season,
        TRIM(GAMETYPE)                                       AS game_type,
        (WIN = 1)                                            AS is_win,
        (HOME = 1)                                           AS is_home,
        NUMMINUTES::FLOAT                                    AS minutes_played,
        COALESCE(POINTS::INT, 0)                             AS pts,
        COALESCE(ASSISTS::INT, 0)                            AS ast,
        COALESCE(REBOUNDSTOTAL::INT, 0)                      AS reb,
        COALESCE(REBOUNDSOFFENSIVE::INT, 0)                  AS oreb,
        COALESCE(REBOUNDSDEFENSIVE::INT, 0)                  AS dreb,
        COALESCE(STEALS::INT, 0)                             AS stl,
        COALESCE(BLOCKS::INT, 0)                             AS blk,
        COALESCE(TURNOVERS::INT, 0)                          AS tov,
        COALESCE(FOULSPERSONAL::INT, 0)                      AS pf,
        COALESCE(FIELDGOALSMADE::INT, 0)                     AS fgm,
        COALESCE(FIELDGOALSATTEMPTED::INT, 0)                AS fga,
        FIELDGOALSPERCENTAGE::FLOAT                          AS fg_pct,
        COALESCE(THREEPOINTERSMADE::INT, 0)                  AS fg3m,
        COALESCE(THREEPOINTERSATTEMPTED::INT, 0)             AS fg3a,
        THREEPOINTERSPERCENTAGE::FLOAT                       AS fg3_pct,
        COALESCE(FREETHROWSMADE::INT, 0)                     AS ftm,
        COALESCE(FREETHROWSATTEMPTED::INT, 0)                AS fta,
        FREETHROWSPERCENTAGE::FLOAT                          AS ft_pct,
        PLUSMINUSPOINTS::FLOAT                               AS plus_minus,
        'jb_seed'                                            AS source,
        CURRENT_TIMESTAMP()                                  AS fetched_at
    FROM JB_HISTORIC_NBA.PUBLIC.PLAYERSTATISTICS1
    WHERE GAMETYPE != 'Preseason'

    UNION

    SELECT
        GAMEID::STRING                                       AS game_id,
        PERSONID::STRING                                     AS player_id,
        TRIM(FIRSTNAME) || ' ' || TRIM(LASTNAME)             AS player_name,
        NULL::INT                                            AS team_id,
        TRIM(PLAYERTEAMCITY) || ' ' || TRIM(PLAYERTEAMNAME)  AS team_name,
        NULL::STRING                                         AS team_abbr,
        TRIM(OPPONENTTEAMCITY) || ' ' || TRIM(OPPONENTTEAMNAME) AS opponent_team_name,
        GAMEDATE::DATE                                       AS game_date,
        NULL::INT                                            AS season,
        TRIM(GAMETYPE)                                       AS game_type,
        (WIN = 1)                                            AS is_win,
        (HOME = 1)                                           AS is_home,
        NUMMINUTES::FLOAT                                    AS minutes_played,
        COALESCE(POINTS::INT, 0)                             AS pts,
        COALESCE(ASSISTS::INT, 0)                            AS ast,
        COALESCE(REBOUNDSTOTAL::INT, 0)                      AS reb,
        COALESCE(REBOUNDSOFFENSIVE::INT, 0)                  AS oreb,
        COALESCE(REBOUNDSDEFENSIVE::INT, 0)                  AS dreb,
        COALESCE(STEALS::INT, 0)                             AS stl,
        COALESCE(BLOCKS::INT, 0)                             AS blk,
        COALESCE(TURNOVERS::INT, 0)                          AS tov,
        COALESCE(FOULSPERSONAL::INT, 0)                      AS pf,
        COALESCE(FIELDGOALSMADE::INT, 0)                     AS fgm,
        COALESCE(FIELDGOALSATTEMPTED::INT, 0)                AS fga,
        FIELDGOALSPERCENTAGE::FLOAT                          AS fg_pct,
        COALESCE(THREEPOINTERSMADE::INT, 0)                  AS fg3m,
        COALESCE(THREEPOINTERSATTEMPTED::INT, 0)             AS fg3a,
        THREEPOINTERSPERCENTAGE::FLOAT                       AS fg3_pct,
        COALESCE(FREETHROWSMADE::INT, 0)                     AS ftm,
        COALESCE(FREETHROWSATTEMPTED::INT, 0)                AS fta,
        FREETHROWSPERCENTAGE::FLOAT                          AS ft_pct,
        PLUSMINUSPOINTS::FLOAT                               AS plus_minus,
        'jb_seed'                                            AS source,
        CURRENT_TIMESTAMP()                                  AS fetched_at
    FROM JB_HISTORIC_NBA.PUBLIC.PLAYERSTATISTICS2
)
SELECT * FROM combined;

-- Verify row count and breakdown
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.player_box_basic;
SELECT game_type, COUNT(*) AS n FROM ZK_NBA.FLAT.player_box_basic
GROUP BY game_type ORDER BY n DESC;
SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date FROM ZK_NBA.FLAT.player_box_basic;

-- Spot check: Jokic in 2023 Finals Game 5
SELECT player_name, pts, ast, reb, fgm, fga, fg3m, fg3a, ftm, fta, plus_minus
FROM ZK_NBA.FLAT.player_box_basic
WHERE game_id = '42200405' AND player_name ILIKE '%Jokic%';
-- Expected: pts=28, ast=4, reb=16, fgm=12, fga=16, fg3m=1, fg3a=3, ftm=3, fta=5, plus_minus=12
