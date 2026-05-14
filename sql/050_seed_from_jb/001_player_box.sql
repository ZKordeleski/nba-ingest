-- Seed ZK_NBA.FLAT.player_box_basic from JB_HISTORIC_NBA.PUBLIC.
--
-- PLAYERSTATISTICS1 covers 2001-12-30 to 2025-04-06 (811,672 rows).
-- PLAYERSTATISTICS2 covers 1946-11-26 to 2001-12-30 (811,671 rows).
-- UNION (not UNION ALL) because the two tables split at 2001-12-30 — the boundary
-- date may appear in both tables. UNION deduplicates on all column values.
-- Combined: ~1,623,343 rows covering the full 1946-2025 history.
--
-- Run after 040_flat_tables.sql. Takes ~30-60s on NBA_INGEST_WH (XSMALL).

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.player_box_basic AS
WITH combined AS (
    -- Modern player stats: 2001-12-30 to 2025-04-06
    SELECT
        GAMEID::STRING                          AS game_id,
        PERSONID::STRING                        AS player_id,
        TRIM(FIRSTNAME) || ' ' || TRIM(LASTNAME) AS player_name,
        NULL::INT                               AS team_id,   -- JB doesn't store team_id in player stats
        TRIM(PLAYERTEAMCITY) || ' ' || TRIM(PLAYERTEAMNAME) AS team_name,
        NULL::STRING                            AS team_abbr, -- Not in JB player stats; derive from games if needed
        TRIM(OPPONENTTEAMCITY) || ' ' || TRIM(OPPONENTTEAMNAME) AS opponent_team_name,
        GAMEDATE::DATE                          AS game_date,
        NULL::INT                               AS season,    -- Not directly in JB player stats; derive from game_date
        TRIM(GAMETYPE)                          AS game_type,
        CASE WHEN WIN = 'W' THEN TRUE ELSE FALSE END AS is_win,
        CASE WHEN HOME = 1 THEN TRUE ELSE FALSE END  AS is_home,
        TRY_TO_DOUBLE(NUMMINUTES)               AS minutes_played,
        TRY_TO_NUMBER(POINTS)                   AS pts,
        TRY_TO_NUMBER(ASSISTS)                  AS ast,
        TRY_TO_NUMBER(REBOUNDSTOTAL)            AS reb,
        TRY_TO_NUMBER(REBOUNDSOFFENSIVE)        AS oreb,
        TRY_TO_NUMBER(REBOUNDSDEFENSIVE)        AS dreb,
        TRY_TO_NUMBER(STEALS)                   AS stl,
        TRY_TO_NUMBER(BLOCKS)                   AS blk,
        TRY_TO_NUMBER(TURNOVERS)                AS tov,
        TRY_TO_NUMBER(FOULSPERSONAL)            AS pf,
        TRY_TO_NUMBER(FIELDGOALSMADE)           AS fgm,
        TRY_TO_NUMBER(FIELDGOALSATTEMPTED)      AS fga,
        TRY_TO_DECIMAL(FIELDGOALSPERCENTAGE, 10, 4) AS fg_pct,
        TRY_TO_NUMBER(THREEPOINTERSMADE)        AS fg3m,
        TRY_TO_NUMBER(THREEPOINTERSATTEMPTED)   AS fg3a,
        TRY_TO_DECIMAL(THREEPOINTERSPERCENTAGE, 10, 4) AS fg3_pct,
        TRY_TO_NUMBER(FREETHROWSMADE)           AS ftm,
        TRY_TO_NUMBER(FREETHROWSATTEMPTED)      AS fta,
        TRY_TO_DECIMAL(FREETHROWSPERCENTAGE, 10, 4) AS ft_pct,
        TRY_TO_DOUBLE(PLUSMINUSPOINTS)          AS plus_minus,
        'jb_seed'                               AS source,
        CURRENT_TIMESTAMP()                     AS fetched_at
    FROM JB_HISTORIC_NBA.PUBLIC.PLAYERSTATISTICS1

    UNION

    -- Historical player stats: 1946-11-26 to 2001-12-30
    SELECT
        GAMEID::STRING                          AS game_id,
        PERSONID::STRING                        AS player_id,
        TRIM(FIRSTNAME) || ' ' || TRIM(LASTNAME) AS player_name,
        NULL::INT                               AS team_id,
        TRIM(PLAYERTEAMCITY) || ' ' || TRIM(PLAYERTEAMNAME) AS team_name,
        NULL::STRING                            AS team_abbr,
        TRIM(OPPONENTTEAMCITY) || ' ' || TRIM(OPPONENTTEAMNAME) AS opponent_team_name,
        GAMEDATE::DATE                          AS game_date,
        NULL::INT                               AS season,
        TRIM(GAMETYPE)                          AS game_type,
        CASE WHEN WIN = 'W' THEN TRUE ELSE FALSE END AS is_win,
        CASE WHEN HOME = 1 THEN TRUE ELSE FALSE END  AS is_home,
        TRY_TO_DOUBLE(NUMMINUTES)               AS minutes_played,
        TRY_TO_NUMBER(POINTS)                   AS pts,
        TRY_TO_NUMBER(ASSISTS)                  AS ast,
        TRY_TO_NUMBER(REBOUNDSTOTAL)            AS reb,
        TRY_TO_NUMBER(REBOUNDSOFFENSIVE)        AS oreb,
        TRY_TO_NUMBER(REBOUNDSDEFENSIVE)        AS dreb,
        TRY_TO_NUMBER(STEALS)                   AS stl,
        TRY_TO_NUMBER(BLOCKS)                   AS blk,
        TRY_TO_NUMBER(TURNOVERS)                AS tov,
        TRY_TO_NUMBER(FOULSPERSONAL)            AS pf,
        TRY_TO_NUMBER(FIELDGOALSMADE)           AS fgm,
        TRY_TO_NUMBER(FIELDGOALSATTEMPTED)      AS fga,
        TRY_TO_DECIMAL(FIELDGOALSPERCENTAGE, 10, 4) AS fg_pct,
        TRY_TO_NUMBER(THREEPOINTERSMADE)        AS fg3m,
        TRY_TO_NUMBER(THREEPOINTERSATTEMPTED)   AS fg3a,
        TRY_TO_DECIMAL(THREEPOINTERSPERCENTAGE, 10, 4) AS fg3_pct,
        TRY_TO_NUMBER(FREETHROWSMADE)           AS ftm,
        TRY_TO_NUMBER(FREETHROWSATTEMPTED)      AS fta,
        TRY_TO_DECIMAL(FREETHROWSPERCENTAGE, 10, 4) AS ft_pct,
        TRY_TO_DOUBLE(PLUSMINUSPOINTS)          AS plus_minus,
        'jb_seed'                               AS source,
        CURRENT_TIMESTAMP()                     AS fetched_at
    FROM JB_HISTORIC_NBA.PUBLIC.PLAYERSTATISTICS2
)
SELECT * FROM combined;

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.player_box_basic;
-- Expected: ~1,623,343

SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date
FROM ZK_NBA.FLAT.player_box_basic;
-- Expected: 1946-11-26 to 2025-04-06
