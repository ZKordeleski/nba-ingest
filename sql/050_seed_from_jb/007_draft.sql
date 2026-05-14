-- Seed ZK_NBA.FLAT.draft from JB_HISTORIC_NBA.PUBLIC.DRAFT_HISTORY.
--
-- DRAFT_HISTORY has 7,990 rows covering 1947-2023.
-- Straight mapping — JB column names closely match our target schema.
-- 2024 and 2025 draft classes are added in Slice 5 from BR.
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- First: inspect the DRAFT_HISTORY schema
-- DESCRIBE TABLE JB_HISTORIC_NBA.PUBLIC.DRAFT_HISTORY;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.draft AS
SELECT
    TRY_TO_NUMBER(PERSON_ID)           AS person_id,
    TRIM(PLAYER_NAME)                  AS player_name,
    TRY_TO_NUMBER(SEASON)              AS season,
    TRY_TO_NUMBER(ROUND_NUMBER)        AS round_number,
    TRY_TO_NUMBER(ROUND_PICK)          AS round_pick,
    TRY_TO_NUMBER(OVERALL_PICK)        AS overall_pick,
    TRIM(DRAFT_TYPE)                   AS draft_type,
    TRY_TO_NUMBER(TEAM_ID)             AS team_id,
    TRIM(TEAM_CITY) || ' ' || TRIM(TEAM_NAME) AS team_abbr,  -- JB may not have abbreviation directly
    TRIM(ORGANIZATION)                 AS organization,
    TRIM(ORGANIZATION_TYPE)            AS organization_type,
    CURRENT_TIMESTAMP()                AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.DRAFT_HISTORY;

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.draft;
-- Expected: ~7,990

SELECT MIN(season) AS min_season, MAX(season) AS max_season FROM ZK_NBA.FLAT.draft;
-- Expected: 1947 to 2023

-- Sanity: 2023 pick #1 should be Victor Wembanyama
SELECT season, overall_pick, player_name, organization
FROM ZK_NBA.FLAT.draft
WHERE season = 2023 AND overall_pick = 1;
-- Expected: Victor Wembanyama, San Antonio Spurs
