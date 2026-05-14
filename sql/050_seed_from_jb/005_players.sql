-- Seed ZK_NBA.FLAT.players from JB_HISTORIC_NBA.PUBLIC.PLAYERS2.
--
-- PLAYERS2 has 6,533 rows with 14 cols. Covers all players who appeared in
-- NBA box scores in the JB dataset.
--
-- Key columns in PLAYERS2:
--   PERSONID, FIRSTNAME, LASTNAME, BIRTHDATE, LASTATTENDED (college),
--   COUNTRY, HEIGHT (inches as float), BODYWEIGHT (lbs as float),
--   GUARD (boolean), FORWARD (boolean), CENTER (boolean),
--   DRAFTYEAR, DRAFTROUND, DRAFTNUMBER
--
-- Position is derived from the boolean columns: if GUARD=1, FORWARD=0, CENTER=0 -> 'G'.
-- Multiple true booleans indicate a combo position (e.g., G-F).
--
-- JB does not have a COMMON_PLAYER_INFO table confirmed in scope;
-- all needed fields come from PLAYERS2 directly.
--
-- Run after 040_flat_tables.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- First: inspect the PLAYERS2 schema to confirm column names
-- DESCRIBE TABLE JB_HISTORIC_NBA.PUBLIC.PLAYERS2;

CREATE OR REPLACE TABLE ZK_NBA.FLAT.players AS
SELECT
    PERSONID::STRING              AS player_id,
    TRIM(FIRSTNAME)               AS first_name,
    TRIM(LASTNAME)                AS last_name,
    TRY_TO_DATE(BIRTHDATE)        AS birth_date,
    TRIM(LASTATTENDED)            AS college,
    TRIM(COUNTRY)                 AS country,
    TRY_TO_DOUBLE(HEIGHT)         AS height_in,
    TRY_TO_DOUBLE(BODYWEIGHT)     AS weight_lb,
    -- Derive position string from the three boolean columns
    CASE
        WHEN GUARD = 1 AND FORWARD = 0 AND CENTER = 0 THEN 'G'
        WHEN GUARD = 0 AND FORWARD = 1 AND CENTER = 0 THEN 'F'
        WHEN GUARD = 0 AND FORWARD = 0 AND CENTER = 1 THEN 'C'
        WHEN GUARD = 1 AND FORWARD = 1 AND CENTER = 0 THEN 'G-F'
        WHEN GUARD = 0 AND FORWARD = 1 AND CENTER = 1 THEN 'F-C'
        WHEN GUARD = 1 AND FORWARD = 0 AND CENTER = 1 THEN 'G-C'
        ELSE NULL
    END                           AS position,
    TRY_TO_NUMBER(DRAFTYEAR)      AS draft_year,
    TRY_TO_NUMBER(DRAFTROUND)     AS draft_round,
    TRY_TO_NUMBER(DRAFTNUMBER)    AS draft_pick,
    NULL::INT                     AS from_year,  -- Not in PLAYERS2; can be derived from player_box_basic
    NULL::INT                     AS to_year,    -- Not in PLAYERS2; can be derived from player_box_basic
    CURRENT_TIMESTAMP()           AS fetched_at
FROM JB_HISTORIC_NBA.PUBLIC.PLAYERS2;

-- Verify
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.players;
-- Expected: ~6,533

SELECT COUNT(*) AS no_position FROM ZK_NBA.FLAT.players WHERE position IS NULL;
-- Expected: a small number (players with no position data in JB)

SELECT COUNT(*) AS undrafted FROM ZK_NBA.FLAT.players WHERE draft_year IS NULL;
-- Expected: some fraction (undrafted players common especially in historical data)
