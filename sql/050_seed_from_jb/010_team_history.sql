-- Seed ZK_NBA.FLAT.team_history from JB_HISTORIC_NBA.PUBLIC.TEAMHISTORIES.
--
-- TEAMHISTORIES has 140 rows covering team relocations and name changes
-- across NBA history (e.g., Seattle SuperSonics -> Oklahoma City Thunder,
-- New Jersey Nets -> Brooklyn Nets, etc.).
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- First: inspect the TEAMHISTORIES schema
-- DESCRIBE TABLE JB_HISTORIC_NBA.PUBLIC.TEAMHISTORIES;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.team_history AS
SELECT
    TRY_TO_NUMBER(TEAM_ID)          AS team_id,
    TRIM(CITY)                      AS city,
    TRIM(NICKNAME)                  AS nickname,
    TRY_TO_NUMBER(YEAR_FOUNDED)     AS year_founded,
    TRY_TO_NUMBER(YEAR_ACTIVE_TILL) AS year_active_till,
    CURRENT_TIMESTAMP()             AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.TEAMHISTORIES;

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.team_history;
-- Expected: ~140

-- Sample: OKC history (should show Seattle SuperSonics era + OKC era)
SELECT city, nickname, year_founded, year_active_till
FROM ZK_NBA.FLAT.team_history
WHERE team_id = (SELECT team_id FROM ZK_NBA.FLAT.teams WHERE abbreviation = 'OKC')
ORDER BY year_founded;
