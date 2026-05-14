-- Seed ZK_NBA.FLAT.teams from JB_HISTORIC_NBA.PUBLIC.TEAM + TEAM_DETAILS.
--
-- Pattern: TRUNCATE + INSERT (preserves DDL comments/PK).
--
-- TEAM has 30 rows (current teams). TEAM_DETAILS has 25 rows — missing
-- ORL, NYK, BOS, CLE, NOP. LEFT JOIN keeps all 30; the 5 missing have NULLs
-- for arena, arena_capacity, head_coach, g_league_affiliate.
--
-- COLUMN MAP (via DESCRIBE 2026-05-14):
--   TEAM:         ID (not TEAM_ID), FULL_NAME, ABBREVIATION, NICKNAME, CITY,
--                 STATE, YEAR_FOUNDED (NUMBER(38,1))
--   TEAM_DETAILS: TEAM_ID, ARENA, ARENACAPACITY (NUMBER(38,1)), HEADCOACH,
--                 DLEAGUEAFFILIATION (pre-dates the 2017 D-League→G-League rename).
--
-- TODO: Manually fill the 5 missing teams from BR after seeding.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

TRUNCATE TABLE ZK_NBA.FLAT.teams;

INSERT INTO ZK_NBA.FLAT.teams (
    team_id, abbreviation, full_name, city, year_founded,
    arena, arena_capacity, head_coach, g_league_affiliate, fetched_at
)
SELECT
    t.ID::INT                             AS team_id,
    TRIM(t.ABBREVIATION)                  AS abbreviation,
    TRIM(t.FULL_NAME)                     AS full_name,
    TRIM(t.CITY)                          AS city,
    t.YEAR_FOUNDED::INT                   AS year_founded,
    TRIM(td.ARENA)                        AS arena,
    td.ARENACAPACITY::INT                 AS arena_capacity,
    TRIM(td.HEADCOACH)                    AS head_coach,
    TRIM(td.DLEAGUEAFFILIATION)           AS g_league_affiliate,
    CURRENT_TIMESTAMP()                   AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.TEAM t
LEFT JOIN JB_HISTORIC_NBA.PUBLIC.TEAM_DETAILS td
    ON t.ID = td.TEAM_ID;

SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.teams;

SELECT abbreviation, full_name, arena, head_coach
FROM ZK_NBA.FLAT.teams
WHERE arena IS NULL
ORDER BY abbreviation;

SELECT abbreviation, full_name FROM ZK_NBA.FLAT.teams ORDER BY abbreviation;
