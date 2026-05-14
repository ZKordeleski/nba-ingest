-- Seed ZK_NBA.FLAT.players from JB_HISTORIC_NBA.PUBLIC.PLAYERS2.
--
-- Pattern: TRUNCATE + INSERT (preserves DDL comments/PK).
--
-- PLAYERS2 has ~6,533 rows — every player who appeared in a JB box score.
--
-- TYPE / SHAPE NOTES (via DESCRIBE 2026-05-14):
--   - GUARD/FORWARD/CENTER are BOOLEAN (not 0/1 NUMBER); use the column directly.
--   - DRAFTYEAR/DRAFTROUND/DRAFTNUMBER are NUMBER(38,1) — ::INT required.
--   - HEIGHT/BODYWEIGHT are NUMBER(38,1) — ::FLOAT works (no narrowing issue).
--   - from_year / to_year are not in PLAYERS2; left NULL for now.
--     Could be derived from MIN/MAX game_date in player_box_basic later.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

TRUNCATE TABLE ZK_NBA.FLAT.players;

INSERT INTO ZK_NBA.FLAT.players (
    player_id, first_name, last_name, birth_date, college, country,
    height_in, weight_lb, position,
    draft_year, draft_round, draft_pick,
    from_year, to_year, fetched_at
)
SELECT
    PERSONID::STRING              AS player_id,
    TRIM(FIRSTNAME)               AS first_name,
    TRIM(LASTNAME)                AS last_name,
    BIRTHDATE                     AS birth_date,
    TRIM(LASTATTENDED)            AS college,
    TRIM(COUNTRY)                 AS country,
    HEIGHT::FLOAT                 AS height_in,
    BODYWEIGHT::FLOAT             AS weight_lb,
    CASE
        WHEN GUARD AND NOT FORWARD AND NOT CENTER THEN 'G'
        WHEN NOT GUARD AND FORWARD AND NOT CENTER THEN 'F'
        WHEN NOT GUARD AND NOT FORWARD AND CENTER THEN 'C'
        WHEN GUARD AND FORWARD AND NOT CENTER THEN 'G-F'
        WHEN NOT GUARD AND FORWARD AND CENTER THEN 'F-C'
        WHEN GUARD AND NOT FORWARD AND CENTER THEN 'G-C'
        WHEN GUARD AND FORWARD AND CENTER THEN 'G-F-C'
        ELSE NULL
    END                           AS position,
    DRAFTYEAR::INT                AS draft_year,
    DRAFTROUND::INT               AS draft_round,
    DRAFTNUMBER::INT              AS draft_pick,
    NULL::INT                     AS from_year,
    NULL::INT                     AS to_year,
    CURRENT_TIMESTAMP()           AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.PLAYERS2;

SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.players;
SELECT COUNT(*) AS no_position FROM ZK_NBA.FLAT.players WHERE position IS NULL;
SELECT COUNT(*) AS undrafted FROM ZK_NBA.FLAT.players WHERE draft_year IS NULL;
SELECT position, COUNT(*) AS n FROM ZK_NBA.FLAT.players
GROUP BY position ORDER BY n DESC;
