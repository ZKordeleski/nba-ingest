-- Seed ZK_NBA.FLAT.teams from JB_HISTORIC_NBA.PUBLIC.TEAM + TEAM_DETAILS.
--
-- TEAM has 30 rows (all current teams).
-- TEAM_DETAILS has only 25 rows — missing ORL, NYK, BOS, CLE, NOP.
-- We LEFT JOIN so all 30 teams appear; the 5 missing teams will have NULL
-- for arena, arena_capacity, head_coach, and g_league_affiliate.
--
-- TODO: After running this seed, manually fill the 5 missing teams from BR:
--   https://www.basketball-reference.com/teams/ORL/
--   https://www.basketball-reference.com/teams/NYK/
--   https://www.basketball-reference.com/teams/BOS/
--   https://www.basketball-reference.com/teams/CLE/
--   https://www.basketball-reference.com/teams/NOP/
-- Use an UPDATE statement or run a separate INSERT for each.
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- First: inspect the TEAM and TEAM_DETAILS schemas
-- DESCRIBE TABLE JB_HISTORIC_NBA.PUBLIC.TEAM;
-- DESCRIBE TABLE JB_HISTORIC_NBA.PUBLIC.TEAM_DETAILS;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.teams AS
SELECT
    TRY_TO_NUMBER(t.TEAM_ID)              AS team_id,
    TRIM(t.ABBREVIATION)                  AS abbreviation,
    TRIM(t.FULL_NAME)                     AS full_name,
    TRIM(t.CITY)                          AS city,
    TRY_TO_NUMBER(t.YEAR_FOUNDED)         AS year_founded,
    TRIM(td.ARENA)                        AS arena,               -- NULL for 5 missing teams
    TRY_TO_NUMBER(td.ARENACAPACITY)       AS arena_capacity,      -- NULL for 5 missing teams
    TRIM(td.HEADCOACH)                    AS head_coach,          -- NULL for 5 missing teams
    TRIM(td.GLEAGUEAFFILIATE)             AS g_league_affiliate,  -- NULL for 5 missing teams
    CURRENT_TIMESTAMP()                   AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.TEAM t
LEFT JOIN JB_HISTORIC_NBA.PUBLIC.TEAM_DETAILS td
    ON t.TEAM_ID = td.TEAM_ID;

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.teams;
-- Expected: 30

-- Show the 5 teams with missing detail data
SELECT abbreviation, full_name, arena, head_coach
FROM ZK_NBA.FLAT.teams
WHERE arena IS NULL;
-- Expected: ORL, NYK, BOS, CLE, NOP (5 rows with NULL arena)

-- Reminder: fill these manually after running this file
SELECT abbreviation, full_name FROM ZK_NBA.FLAT.teams ORDER BY abbreviation;
