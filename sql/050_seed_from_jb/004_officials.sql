-- Seed ZK_NBA.FLAT.game_officials from JB_HISTORIC_NBA.PUBLIC.OFFICIALS.
--
-- Pattern: TRUNCATE + INSERT (preserves DDL comments/PK).
--
-- OFFICIALS has ~70K rows covering modern games. ~235 distinct officials.
--
-- PRE-SEED VALIDATION FINDINGS (against JB source 2026-05-11):
--   - 3 officials/game is normal (23,294 games), 4 for NBA Finals (238 games).
--   - 2 officials/game appears for ~30 old games (likely partial data).
--   - 5/6 officials/game in 13 games appears to be JB duplicate-row artifact —
--     SELECT DISTINCT below collapses these to the correct count.
--
-- TYPE MAP: GAME_ID, OFFICIAL_ID, JERSEY_NUM all NUMBER(38,0) — TRY_TO_NUMBER fine.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

TRUNCATE TABLE ZK_NBA.FLAT.game_officials;

INSERT INTO ZK_NBA.FLAT.game_officials (
    game_id, official_id, first_name, last_name, jersey_num, fetched_at
)
SELECT DISTINCT
    GAME_ID::STRING              AS game_id,
    -- official_id is now STRING (was INT) to accommodate BR slug fallbacks
    -- for refs we can't resolve via JB xref. JB's NBA Stats API integer IDs
    -- get stringified here so the column has a single uniform type.
    OFFICIAL_ID::STRING          AS official_id,
    TRIM(FIRST_NAME)             AS first_name,
    TRIM(LAST_NAME)              AS last_name,
    JERSEY_NUM::INT              AS jersey_num,
    CURRENT_TIMESTAMP()          AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.OFFICIALS;

SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.game_officials;
SELECT COUNT(DISTINCT official_id) AS distinct_officials FROM ZK_NBA.FLAT.game_officials;
SELECT COUNT(DISTINCT game_id) AS distinct_games FROM ZK_NBA.FLAT.game_officials;
