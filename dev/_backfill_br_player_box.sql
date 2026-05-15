-- Focused backfill: just player_box_basic BR rows.
-- (games and game_inactives already done in previous run before divide-by-zero
-- aborted the verification.)
--
-- Step A: resolve team_id, team_name, season, game_type via abbr lookup.
-- Step B: derive opponent_team_name from games (now that games.team_id is populated).

USE ROLE DEVELOPER_ADMIN;
USE WAREHOUSE NBA_INGEST_WH;
USE DATABASE ZK_NBA;

-- Step A
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

-- Step B
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

-- Verification with NULLIF guards.
SELECT
    'player_box_basic (br)' AS scope, COUNT(*) AS total,
    ROUND(100.0 * (1 - COUNT(team_id)::FLOAT / NULLIF(COUNT(*), 0)), 2)   AS pct_null_team_id,
    ROUND(100.0 * (1 - COUNT(team_name)::FLOAT / NULLIF(COUNT(*), 0)), 2) AS pct_null_team_name,
    ROUND(100.0 * (1 - COUNT(opponent_team_name)::FLOAT / NULLIF(COUNT(*), 0)), 2) AS pct_null_opp_name,
    ROUND(100.0 * (1 - COUNT(season)::FLOAT / NULLIF(COUNT(*), 0)), 2)    AS pct_null_season,
    ROUND(100.0 * (1 - COUNT(game_type)::FLOAT / NULLIF(COUNT(*), 0)), 2) AS pct_null_game_type
FROM FLAT.player_box_basic
WHERE source = 'br_scrape';

-- Spot check Wembanyama (BR-scraped).
SELECT player_name, team_id, team_abbr, team_name, opponent_team_name, season, game_type, pts
FROM FLAT.player_box_basic
WHERE source = 'br_scrape' AND player_name ILIKE '%Wembanyama%'
LIMIT 3;
