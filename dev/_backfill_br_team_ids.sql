-- One-shot backfill: resolve team_id and related fields for BR-scraped rows.
--
-- Applies to existing rows in:
--   FLAT.games            (3,940 rows: home/away team_id, season_id, plus_minus)
--   FLAT.player_box_basic (104,065 rows: team_id, team_name, opponent_team_name,
--                          season, game_type)
--   FLAT.game_inactives   (33,658 rows: team_id)
--
-- Resolution pattern: BR team_abbr -> NBA team_abbr (via CASE for 3 mismatches)
-- -> FLAT.teams.team_id. Season derived from game_date. season_id derived from
-- game_id first digit + (season-1). game_type derived from game_id first digit.
--
-- Validation pre-run (dev/_validate_team_lookup.sql 2026-05-15):
--   BR uses 30 distinct abbreviations; after BRK->BKN, CHO->CHA, PHO->PHX
--   translation, all 30 match FLAT.teams exactly.
--
-- Run order matters: games first (so player_box can derive opponent via games),
-- then player_box, then game_inactives.
--
-- After this runs successfully, integrate the same lookup logic into:
--   src/nba_ingest/jobs/daily_settle.py and backfill.py
-- so future writes don't need this backfill again. (Code change is a separate
-- task; this SQL fixes existing data.)

USE ROLE DEVELOPER_ADMIN;
USE WAREHOUSE NBA_INGEST_WH;
USE DATABASE ZK_NBA;

-- --------------------------------------------------------------------------
-- Step 1: games. Populate home/away team_id, season_id, plus_minus.
-- --------------------------------------------------------------------------
UPDATE FLAT.games g
SET
    home_team_id     = nba_home.team_id,
    away_team_id     = nba_away.team_id,
    season_id        = TRY_TO_NUMBER(LEFT(g.game_id, 1) || LPAD((g.season - 1)::STRING, 4, '0')),
    home_plus_minus  = g.home_pts - g.away_pts,
    away_plus_minus  = g.away_pts - g.home_pts
FROM
    FLAT.teams nba_home,
    FLAT.teams nba_away
WHERE
    g.source = 'br_scrape'
    AND nba_home.abbreviation = CASE g.home_team_abbr
                                  WHEN 'BRK' THEN 'BKN'
                                  WHEN 'CHO' THEN 'CHA'
                                  WHEN 'PHO' THEN 'PHX'
                                  ELSE g.home_team_abbr
                                END
    AND nba_away.abbreviation = CASE g.away_team_abbr
                                  WHEN 'BRK' THEN 'BKN'
                                  WHEN 'CHO' THEN 'CHA'
                                  WHEN 'PHO' THEN 'PHX'
                                  ELSE g.away_team_abbr
                                END;

-- --------------------------------------------------------------------------
-- Step 2: player_box_basic. Populate team_id, team_name, season, game_type.
-- (opponent_team_name handled in step 2b — needs games.team_id from step 1.)
-- --------------------------------------------------------------------------
UPDATE FLAT.player_box_basic pbb
SET
    team_id   = nba_team.team_id,
    team_name = nba_team.full_name,
    season    = CASE WHEN MONTH(pbb.game_date) >= 10
                     THEN YEAR(pbb.game_date) + 1
                     ELSE YEAR(pbb.game_date)
                END,
    game_type = CASE LEFT(pbb.game_id, 1)
                  WHEN '0' THEN 'Preseason'
                  WHEN '1' THEN 'Preseason'
                  WHEN '2' THEN 'Regular Season'
                  WHEN '4' THEN 'Playoffs'
                  WHEN '5' THEN 'Play-in Tournament'
                  WHEN '6' THEN 'NBA Cup'
                  ELSE NULL
                END
FROM FLAT.teams nba_team
WHERE
    pbb.source = 'br_scrape'
    AND nba_team.abbreviation = CASE pbb.team_abbr
                                  WHEN 'BRK' THEN 'BKN'
                                  WHEN 'CHO' THEN 'CHA'
                                  WHEN 'PHO' THEN 'PHX'
                                  ELSE pbb.team_abbr
                                END;

-- --------------------------------------------------------------------------
-- Step 2b: player_box_basic.opponent_team_name from games (now populated).
-- --------------------------------------------------------------------------
UPDATE FLAT.player_box_basic pbb
SET opponent_team_name = nba_opp.full_name
FROM FLAT.games g, FLAT.teams nba_opp
WHERE
    pbb.source = 'br_scrape'
    AND g.game_id = pbb.game_id
    AND nba_opp.team_id = CASE
                            WHEN g.home_team_id = pbb.team_id THEN g.away_team_id
                            WHEN g.away_team_id = pbb.team_id THEN g.home_team_id
                            ELSE NULL
                          END;

-- --------------------------------------------------------------------------
-- Step 3: game_inactives.team_id.
-- --------------------------------------------------------------------------
UPDATE FLAT.game_inactives gi
SET team_id = nba_team.team_id
FROM FLAT.teams nba_team
WHERE
    gi.br_player_slug IS NOT NULL  -- BR-scraped rows
    AND nba_team.abbreviation = CASE gi.team_abbr
                                  WHEN 'BRK' THEN 'BKN'
                                  WHEN 'CHO' THEN 'CHA'
                                  WHEN 'PHO' THEN 'PHX'
                                  ELSE gi.team_abbr
                                END;

-- --------------------------------------------------------------------------
-- Verification: re-run the audit columns. Expect 0% NULL on the fixed cols.
-- --------------------------------------------------------------------------
SELECT
    'games (br)' AS scope, COUNT(*) AS total,
    ROUND(100.0 * (1 - COUNT(home_team_id)::FLOAT / COUNT(*)), 2) AS pct_null_home_id,
    ROUND(100.0 * (1 - COUNT(away_team_id)::FLOAT / COUNT(*)), 2) AS pct_null_away_id,
    ROUND(100.0 * (1 - COUNT(season_id)::FLOAT / COUNT(*)), 2)    AS pct_null_season_id,
    ROUND(100.0 * (1 - COUNT(home_plus_minus)::FLOAT / COUNT(*)), 2) AS pct_null_home_pm
FROM FLAT.games
WHERE source = 'br_scrape';

SELECT
    'player_box_basic (br)' AS scope, COUNT(*) AS total,
    ROUND(100.0 * (1 - COUNT(team_id)::FLOAT / COUNT(*)), 2)   AS pct_null_team_id,
    ROUND(100.0 * (1 - COUNT(team_name)::FLOAT / COUNT(*)), 2) AS pct_null_team_name,
    ROUND(100.0 * (1 - COUNT(opponent_team_name)::FLOAT / COUNT(*)), 2) AS pct_null_opp_name,
    ROUND(100.0 * (1 - COUNT(season)::FLOAT / COUNT(*)), 2)    AS pct_null_season,
    ROUND(100.0 * (1 - COUNT(game_type)::FLOAT / COUNT(*)), 2) AS pct_null_game_type
FROM FLAT.player_box_basic
WHERE source = 'br_scrape';

SELECT
    'game_inactives (br)' AS scope, COUNT(*) AS total,
    ROUND(100.0 * (1 - COUNT(team_id)::FLOAT / COUNT(*)), 2) AS pct_null_team_id
FROM FLAT.game_inactives
WHERE br_player_slug IS NOT NULL;

-- Spot check: Wembanyama's row (BR-scraped). Should now have team_id, name, etc.
SELECT player_name, team_id, team_abbr, team_name, opponent_team_name, season, game_type, pts
FROM FLAT.player_box_basic
WHERE source = 'br_scrape' AND player_name ILIKE '%Wembanyama%'
LIMIT 3;
