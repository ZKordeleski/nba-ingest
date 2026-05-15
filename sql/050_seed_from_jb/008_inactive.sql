-- Seed ZK_NBA.FLAT.game_inactives from JB_HISTORIC_NBA.PUBLIC.INACTIVE_PLAYERS.
--
-- Pattern: TRUNCATE + INSERT (preserves DDL comments/PK).
--
-- INACTIVE_PLAYERS has ~110K rows. Lists players who were on the active roster
-- but did not play (injury, rest, etc.). Modern games only.
--
-- TYPE MAP (via DESCRIBE 2026-05-14):
--   GAME_ID, PLAYER_ID, JERSEY_NUM, TEAM_ID: all NUMBER(38,0) — TRY_TO_NUMBER fine.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- DELETE (not TRUNCATE) so BR-scraped rows survive a re-seed. game_inactives
-- has no explicit source column, so we infer JB rows via br_player_slug IS NULL.
-- See 001_player_box.sql for the full rationale.
DELETE FROM ZK_NBA.FLAT.game_inactives WHERE br_player_slug IS NULL;

INSERT INTO ZK_NBA.FLAT.game_inactives (
    game_id, player_id, first_name, last_name, jersey_num,
    team_id, team_abbr, fetched_at
)
SELECT
    GAME_ID::STRING              AS game_id,
    -- player_id is now STRING (was INT) to accommodate BR slug fallbacks for
    -- the rare unresolvable players. JB's NBA Stats API integer IDs get
    -- stringified here so the column has a single uniform type.
    PLAYER_ID::STRING            AS player_id,
    TRIM(FIRST_NAME)             AS first_name,
    TRIM(LAST_NAME)              AS last_name,
    JERSEY_NUM::INT              AS jersey_num,
    TEAM_ID::INT                 AS team_id,
    TRIM(TEAM_ABBREVIATION)      AS team_abbr,
    CURRENT_TIMESTAMP()          AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.INACTIVE_PLAYERS;

SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.game_inactives;
SELECT COUNT(DISTINCT game_id) AS distinct_games FROM ZK_NBA.FLAT.game_inactives;
