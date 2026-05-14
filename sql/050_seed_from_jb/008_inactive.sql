-- Seed ZK_NBA.FLAT.game_inactives from JB_HISTORIC_NBA.PUBLIC.INACTIVE_PLAYERS.
--
-- INACTIVE_PLAYERS has 110,191 rows covering the modern era.
-- Lists players who were on the active roster but did not play (injured, rested, etc.).
-- Straight mapping — JB column names closely match our target schema.
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- First: inspect the INACTIVE_PLAYERS schema
-- DESCRIBE TABLE JB_HISTORIC_NBA.PUBLIC.INACTIVE_PLAYERS;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.game_inactives AS
SELECT
    GAME_ID::STRING              AS game_id,
    TRY_TO_NUMBER(PLAYER_ID)    AS player_id,
    TRIM(FIRST_NAME)             AS first_name,
    TRIM(LAST_NAME)              AS last_name,
    TRY_TO_NUMBER(JERSEY_NUM)   AS jersey_num,
    TRY_TO_NUMBER(TEAM_ID)      AS team_id,
    TRIM(TEAM_ABBREVIATION)      AS team_abbr,
    CURRENT_TIMESTAMP()          AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.INACTIVE_PLAYERS;

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.game_inactives;
-- Expected: ~110,191

SELECT COUNT(DISTINCT game_id) AS distinct_games FROM ZK_NBA.FLAT.game_inactives;
-- Expected: a large subset of modern games (most games have 2+ inactives per team)
