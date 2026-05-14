-- Seed ZK_NBA.FLAT.draft from JB_HISTORIC_NBA.PUBLIC.DRAFT_HISTORY.
--
-- DRAFT_HISTORY has 7,990 rows covering 1947-2023.
-- 2024 and 2025 draft classes are added in Slice 5 from BR.
--
-- PRE-SEED VALIDATION FINDINGS (run against JB source 2026-05-11):
--   - Historical seasons (1948-1956) have OVERALL_PICK = 0 for hundreds of picks.
--     These are territorial picks and supplemental picks that predate pick numbering.
--     Using PERSON_ID as the primary key instead of (season, overall_pick) to avoid
--     collisions. OVERALL_PICK = 0 is preserved as data, not treated as an error.
--   - TEAM_ABBREVIATION column exists in JB (confirmed via DESCRIBE) — use it directly.
--   - No duplicate (SEASON, OVERALL_PICK) pairs for OVERALL_PICK > 0.
--   - Verified: 2023 pick #1 = Victor Wembanyama (SAS, Metropolitans 92 France).
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.draft AS
SELECT
    TRY_TO_NUMBER(PERSON_ID)           AS person_id,        -- Primary key: stable across eras
    TRIM(PLAYER_NAME)                  AS player_name,
    TRY_TO_NUMBER(SEASON)              AS season,
    TRY_TO_NUMBER(ROUND_NUMBER)        AS round_number,
    TRY_TO_NUMBER(ROUND_PICK)          AS round_pick,
    TRY_TO_NUMBER(OVERALL_PICK)        AS overall_pick,      -- 0 for pre-numbered-era picks
    TRIM(DRAFT_TYPE)                   AS draft_type,
    TRY_TO_NUMBER(TEAM_ID)             AS team_id,
    TRIM(TEAM_ABBREVIATION)            AS team_abbr,         -- JB has this column directly
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
