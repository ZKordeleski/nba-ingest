-- Seed ZK_NBA.FLAT.game_officials from JB_HISTORIC_NBA.PUBLIC.OFFICIALS.
--
-- OFFICIALS has 70,971 rows covering 23,575 games (modern only).
-- 235 distinct officials across the dataset.
-- Straight mapping — column names in JB closely match our target schema.
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- First: inspect the OFFICIALS schema
-- DESCRIBE TABLE JB_HISTORIC_NBA.PUBLIC.OFFICIALS;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.game_officials AS
SELECT
    GAME_ID::STRING              AS game_id,
    TRY_TO_NUMBER(OFFICIAL_ID)  AS official_id,
    TRIM(FIRST_NAME)             AS first_name,
    TRIM(LAST_NAME)              AS last_name,
    TRY_TO_NUMBER(JERSEY_NUM)   AS jersey_num,
    CURRENT_TIMESTAMP()          AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.OFFICIALS;

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.game_officials;
-- Expected: ~70,971

SELECT COUNT(DISTINCT official_id) AS distinct_officials FROM ZK_NBA.FLAT.game_officials;
-- Expected: ~235

SELECT COUNT(DISTINCT game_id) AS distinct_games FROM ZK_NBA.FLAT.game_officials;
-- Expected: ~23,575
