-- Seed ZK_NBA.FLAT.team_history from JB_HISTORIC_NBA.PUBLIC.TEAMHISTORIES.
--
-- Pattern: TRUNCATE + INSERT (preserves DDL comments/PK).
--
-- TEAMHISTORIES has 140 rows total across multiple leagues. Filtering to
-- LEAGUE = 'NBA' yields 72 rows of NBA franchise relocations and rebrands
-- (e.g., Seattle SuperSonics → Oklahoma City Thunder).
--
-- COLUMN MAP (via DESCRIBE 2026-05-14):
--   TEAMID, TEAMCITY, TEAMNAME, TEAMABBREV, SEASONFOUNDED, SEASONACTIVETILL, LEAGUE.
--   (Not TEAM_ID / CITY / NICKNAME / YEAR_FOUNDED / YEAR_ACTIVE_TILL.)

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

TRUNCATE TABLE ZK_NBA.FLAT.team_history;

INSERT INTO ZK_NBA.FLAT.team_history (
    team_id, city, nickname, year_founded, year_active_till, fetched_at
)
SELECT
    TEAMID::INT                      AS team_id,
    TRIM(TEAMCITY)                   AS city,
    TRIM(TEAMNAME)                   AS nickname,
    SEASONFOUNDED::INT               AS year_founded,
    NULLIF(SEASONACTIVETILL::INT, 2100) AS year_active_till,  -- JB uses 2100 as "still active" sentinel
    CURRENT_TIMESTAMP()              AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.TEAMHISTORIES
WHERE LEAGUE = 'NBA';

SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.team_history;

-- Spot: OKC history should show Seattle SuperSonics + OKC Thunder eras
SELECT city, nickname, year_founded, year_active_till
FROM ZK_NBA.FLAT.team_history
WHERE team_id = (SELECT team_id FROM ZK_NBA.FLAT.teams WHERE abbreviation = 'OKC')
ORDER BY year_founded;
