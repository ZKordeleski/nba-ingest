-- Seed ZK_NBA.FLAT.draft from JB_HISTORIC_NBA.PUBLIC.DRAFT_HISTORY.
--
-- Pattern: TRUNCATE + INSERT (preserves DDL comments/PK).
--
-- DRAFT_HISTORY has ~7,990 rows covering 1947-2023.
-- 2024 and 2025 draft classes added later from BR (Slice 5).
--
-- PRE-SEED VALIDATION FINDINGS (against JB source 2026-05-11):
--   - Historical 1948-1956 seasons have OVERALL_PICK = 0 for hundreds of picks
--     (territorial / supplemental picks predating pick numbering).
--   - FLAT.draft.PRIMARY KEY is (season, overall_pick) in the DDL — this seed
--     will fail strict-PK if it contains duplicate (season, 0) pairs.
--     Snowflake PKs are informational (not enforced), so insert succeeds; the
--     constraint is documentation only.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

TRUNCATE TABLE ZK_NBA.FLAT.draft;

INSERT INTO ZK_NBA.FLAT.draft (
    person_id, player_name, season, round_number, round_pick, overall_pick,
    draft_type, team_id, team_abbr, organization, organization_type, fetched_at
)
SELECT
    PERSON_ID::INT                     AS person_id,
    TRIM(PLAYER_NAME)                  AS player_name,
    SEASON::INT                        AS season,
    ROUND_NUMBER::INT                  AS round_number,
    ROUND_PICK::INT                    AS round_pick,
    OVERALL_PICK::INT                  AS overall_pick,
    TRIM(DRAFT_TYPE)                   AS draft_type,
    TEAM_ID::INT                       AS team_id,
    TRIM(TEAM_ABBREVIATION)            AS team_abbr,
    TRIM(ORGANIZATION)                 AS organization,
    TRIM(ORGANIZATION_TYPE)            AS organization_type,
    CURRENT_TIMESTAMP()                AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.DRAFT_HISTORY;

SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.draft;
SELECT MIN(season) AS min_season, MAX(season) AS max_season FROM ZK_NBA.FLAT.draft;

-- Sanity: 2023 pick #1 should be Victor Wembanyama
SELECT season, overall_pick, player_name, organization
FROM ZK_NBA.FLAT.draft
WHERE season = 2023 AND overall_pick = 1;
