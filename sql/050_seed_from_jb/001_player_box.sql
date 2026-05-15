-- Seed ZK_NBA.FLAT.player_box_basic from JB_HISTORIC_NBA.PUBLIC.
--
-- Pattern: TRUNCATE + INSERT (not CREATE OR REPLACE TABLE AS SELECT) so that
-- the typed schema, column comments, and PK constraints from 040_flat_tables.sql
-- remain intact. INSERT also strict-type-checks each column against the DDL.
--
-- PLAYERSTATISTICS1 covers 2001-12-30 to 2025-04-06 (~811K rows).
-- PLAYERSTATISTICS2 covers 1946-11-26 to 2001-12-30 (~811K rows).
-- Combined with UNION (deduplicates identical rows): ~1.6M rows before filtering.
--
-- PRE-SEED VALIDATION FINDINGS (against JB source 2026-05-11):
--   - PS1 includes 54,580 Preseason rows — excluded here (not real games).
--   - PS1/PS2 boundary (2001-12-30) has ZERO overlapping (GAMEID,PERSONID) pairs.
--   - 1,219 rows have NULL POINTS; 137,419 have NULL MINUTES. DNP entries:
--     COALESCE counting stats to 0; minutes_played stays NULL.
--   - WIN/HOME are NUMBER(38,0); 1=true, 0=false.
--
-- TEAM-ID RESOLUTION (added 2026-05-15):
--   PLAYERSTATISTICS1/2 store only TEAMCITY+TEAMNAME strings, no TEAMID column.
--   We resolve team_id via JOIN to FLAT.team_history on (city || ' ' || nickname)
--   with date-range filtering, then look up team_abbr from FLAT.teams.
--   Pre-applied validation (dev/_validate_team_lookup.sql 2026-05-15):
--     1,661 distinct (name, year) pairs match exactly 1 team_id.
--     0 multi-match cases (date-range filtering is tight).
--     56 unmatched pairs — BAA-era and defunct franchises (~3% of rows).
--     The 56 unmatched fall in <1965 historical games; modern queries unaffected.
--
-- SEASON DERIVATION (added 2026-05-15):
--   PLAYERSTATISTICS1/2 have no SEASON column. Convention: season = end year
--   of the spanning NBA season. Oct-Dec games belong to next season's end year;
--   Jan-Jun games belong to current calendar year.
--
-- TYPE MAP (discovered via DESCRIBE 2026-05-14):
--   - Stat cols in PS1/PS2 are NUMBER(38,1); ::INT permits truncation
--     (TRY_TO_NUMBER refuses NUMBER(38,1) -> NUMBER(38,0)).
--   - PCT cols differ in scale between PS1 (NUMBER(38,15)) and PS2
--     (NUMBER(38,3)) — explicit ::FLOAT on both branches keeps UNION clean.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- DELETE (not TRUNCATE) so BR-scraped rows survive a re-seed. The seed only
-- owns jb_seed rows; the br_scrape rows are written by daily_settle/backfill
-- and have their own write path. A blanket TRUNCATE here would wipe BR data
-- as collateral damage (we learned this the hard way on 2026-05-15).
DELETE FROM ZK_NBA.FLAT.player_box_basic WHERE source = 'jb_seed';

INSERT INTO ZK_NBA.FLAT.player_box_basic (
    game_id, player_id, player_name, team_id, team_name, team_abbr,
    opponent_team_name, game_date, season, game_type, is_win, is_home,
    minutes_played, pts, ast, reb, oreb, dreb, stl, blk, tov, pf,
    fgm, fga, fg_pct, fg3m, fg3a, fg3_pct, ftm, fta, ft_pct,
    plus_minus, source, fetched_at
)
WITH combined AS (
    SELECT
        GAMEID::STRING                                       AS game_id,
        PERSONID::STRING                                     AS player_id,
        TRIM(FIRSTNAME) || ' ' || TRIM(LASTNAME)             AS player_name,
        TRIM(PLAYERTEAMCITY) || ' ' || TRIM(PLAYERTEAMNAME)  AS team_name,
        TRIM(OPPONENTTEAMCITY) || ' ' || TRIM(OPPONENTTEAMNAME) AS opponent_team_name,
        GAMEDATE::DATE                                       AS game_date,
        TRIM(GAMETYPE)                                       AS game_type,
        (WIN = 1)                                            AS is_win,
        (HOME = 1)                                           AS is_home,
        NUMMINUTES::FLOAT                                    AS minutes_played,
        COALESCE(POINTS::INT, 0)                             AS pts,
        COALESCE(ASSISTS::INT, 0)                            AS ast,
        COALESCE(REBOUNDSTOTAL::INT, 0)                      AS reb,
        COALESCE(REBOUNDSOFFENSIVE::INT, 0)                  AS oreb,
        COALESCE(REBOUNDSDEFENSIVE::INT, 0)                  AS dreb,
        COALESCE(STEALS::INT, 0)                             AS stl,
        COALESCE(BLOCKS::INT, 0)                             AS blk,
        COALESCE(TURNOVERS::INT, 0)                          AS tov,
        COALESCE(FOULSPERSONAL::INT, 0)                      AS pf,
        COALESCE(FIELDGOALSMADE::INT, 0)                     AS fgm,
        COALESCE(FIELDGOALSATTEMPTED::INT, 0)                AS fga,
        FIELDGOALSPERCENTAGE::FLOAT                          AS fg_pct,
        COALESCE(THREEPOINTERSMADE::INT, 0)                  AS fg3m,
        COALESCE(THREEPOINTERSATTEMPTED::INT, 0)             AS fg3a,
        THREEPOINTERSPERCENTAGE::FLOAT                       AS fg3_pct,
        COALESCE(FREETHROWSMADE::INT, 0)                     AS ftm,
        COALESCE(FREETHROWSATTEMPTED::INT, 0)                AS fta,
        FREETHROWSPERCENTAGE::FLOAT                          AS ft_pct,
        PLUSMINUSPOINTS::FLOAT                               AS plus_minus
    FROM JB_HISTORIC_NBA.PUBLIC.PLAYERSTATISTICS1
    WHERE GAMETYPE != 'Preseason'

    UNION

    SELECT
        GAMEID::STRING                                       AS game_id,
        PERSONID::STRING                                     AS player_id,
        TRIM(FIRSTNAME) || ' ' || TRIM(LASTNAME)             AS player_name,
        TRIM(PLAYERTEAMCITY) || ' ' || TRIM(PLAYERTEAMNAME)  AS team_name,
        TRIM(OPPONENTTEAMCITY) || ' ' || TRIM(OPPONENTTEAMNAME) AS opponent_team_name,
        GAMEDATE::DATE                                       AS game_date,
        TRIM(GAMETYPE)                                       AS game_type,
        (WIN = 1)                                            AS is_win,
        (HOME = 1)                                           AS is_home,
        NUMMINUTES::FLOAT                                    AS minutes_played,
        COALESCE(POINTS::INT, 0)                             AS pts,
        COALESCE(ASSISTS::INT, 0)                            AS ast,
        COALESCE(REBOUNDSTOTAL::INT, 0)                      AS reb,
        COALESCE(REBOUNDSOFFENSIVE::INT, 0)                  AS oreb,
        COALESCE(REBOUNDSDEFENSIVE::INT, 0)                  AS dreb,
        COALESCE(STEALS::INT, 0)                             AS stl,
        COALESCE(BLOCKS::INT, 0)                             AS blk,
        COALESCE(TURNOVERS::INT, 0)                          AS tov,
        COALESCE(FOULSPERSONAL::INT, 0)                      AS pf,
        COALESCE(FIELDGOALSMADE::INT, 0)                     AS fgm,
        COALESCE(FIELDGOALSATTEMPTED::INT, 0)                AS fga,
        FIELDGOALSPERCENTAGE::FLOAT                          AS fg_pct,
        COALESCE(THREEPOINTERSMADE::INT, 0)                  AS fg3m,
        COALESCE(THREEPOINTERSATTEMPTED::INT, 0)             AS fg3a,
        THREEPOINTERSPERCENTAGE::FLOAT                       AS fg3_pct,
        COALESCE(FREETHROWSMADE::INT, 0)                     AS ftm,
        COALESCE(FREETHROWSATTEMPTED::INT, 0)                AS fta,
        FREETHROWSPERCENTAGE::FLOAT                          AS ft_pct,
        PLUSMINUSPOINTS::FLOAT                               AS plus_minus
    FROM JB_HISTORIC_NBA.PUBLIC.PLAYERSTATISTICS2
)
SELECT
    c.game_id,
    c.player_id,
    c.player_name,
    th.team_id              AS team_id,
    c.team_name,
    nba.abbreviation        AS team_abbr,
    c.opponent_team_name,
    c.game_date,
    CASE WHEN MONTH(c.game_date) >= 10
         THEN YEAR(c.game_date) + 1
         ELSE YEAR(c.game_date)
    END                     AS season,
    c.game_type,
    c.is_win,
    c.is_home,
    c.minutes_played,
    c.pts, c.ast, c.reb, c.oreb, c.dreb, c.stl, c.blk, c.tov, c.pf,
    c.fgm, c.fga, c.fg_pct, c.fg3m, c.fg3a, c.fg3_pct,
    c.ftm, c.fta, c.ft_pct, c.plus_minus,
    'jb_seed'               AS source,
    CURRENT_TIMESTAMP()     AS fetched_at
FROM combined c
LEFT JOIN ZK_NBA.FLAT.team_history th
       ON TRIM(th.city) || ' ' || TRIM(th.nickname) = c.team_name
      AND EXTRACT(YEAR FROM c.game_date) BETWEEN th.year_founded
                                             AND COALESCE(th.year_active_till, 9999)
LEFT JOIN ZK_NBA.FLAT.teams nba
       ON nba.team_id = th.team_id;

-- Verify row count and breakdown
SELECT COUNT(*) AS total_rows FROM ZK_NBA.FLAT.player_box_basic;
SELECT game_type, COUNT(*) AS n FROM ZK_NBA.FLAT.player_box_basic
GROUP BY game_type ORDER BY n DESC;
SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date FROM ZK_NBA.FLAT.player_box_basic;

-- Post-fix audit: team_id / team_abbr / season should now be 0% NULL
-- (modulo the ~3% historical BAA/defunct cases noted above).
SELECT
    source,
    COUNT(*) AS total,
    ROUND(100.0 * (1 - COUNT(team_id)::FLOAT / COUNT(*)), 2)   AS pct_null_team_id,
    ROUND(100.0 * (1 - COUNT(team_abbr)::FLOAT / COUNT(*)), 2) AS pct_null_team_abbr,
    ROUND(100.0 * (1 - COUNT(season)::FLOAT / COUNT(*)), 2)    AS pct_null_season
FROM ZK_NBA.FLAT.player_box_basic
WHERE source = 'jb_seed'
GROUP BY source;

-- Spot check: Jokic in 2023 Finals Game 5
SELECT player_name, team_id, team_abbr, season, pts, ast, reb, fgm, fga, fg3m, fg3a, ftm, fta, plus_minus
FROM ZK_NBA.FLAT.player_box_basic
WHERE game_id = '42200405' AND player_name ILIKE '%Jokic%';
-- Expected: team_id=1610612743, team_abbr=DEN, season=2023,
--           pts=28, ast=4, reb=16, fgm=12, fga=16, fg3m=1, fg3a=3, ftm=3, fta=5, plus_minus=12
