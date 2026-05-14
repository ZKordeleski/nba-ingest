-- Slice 1 validation: spot checks against known facts.
-- These verify correct data mapping, not just row counts.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- ============================================================
-- 2023 NBA Finals Game 5 (DEN 94, MIA 89 — Denver wins title)
-- game_id = 42200405 (NBA standard format: 4=playoffs, 22=2022-23, 00405=game)
-- ============================================================

-- Game record
SELECT game_id, game_date, home_team_abbr, home_pts, away_team_abbr, away_pts, season_type
FROM ZK_NBA.FLAT.games
WHERE game_date = '2023-06-12';
-- Expected: game_id=42200405, home=DEN 94, away=MIA 89, season_type=Playoffs

-- Top 5 scorers in that game
SELECT player_name, team_abbr, pts, ast, reb, plus_minus
FROM ZK_NBA.FLAT.player_box_basic
WHERE game_id = '42200405'
ORDER BY pts DESC
LIMIT 5;
-- Expected: Nikola Jokic at top (he scored 28 pts, 16 reb, 12 ast in Game 5)
-- Jimmy Butler likely in top 5 as well

-- Jokic's triple-double in Finals Game 5
SELECT player_name, pts, ast, reb, stl, blk, plus_minus
FROM ZK_NBA.FLAT.player_box_basic
WHERE game_id = '42200405'
  AND player_name LIKE '%Jokic%';
-- Expected: 28 pts, 12 ast, 16 reb (triple-double)

-- ============================================================
-- 2023 NBA Draft Pick #1: Victor Wembanyama (San Antonio Spurs)
-- ============================================================

SELECT season, overall_pick, player_name, organization, team_id
FROM ZK_NBA.FLAT.draft
WHERE season = 2023 AND overall_pick = 1;
-- Expected: Victor Wembanyama, San Antonio Spurs

-- Top 5 picks of the 2023 draft
SELECT overall_pick, player_name, organization
FROM ZK_NBA.FLAT.draft
WHERE season = 2023 AND overall_pick <= 5
ORDER BY overall_pick;
-- Expected: Wembanyama (1), Scoot Henderson (2), Brandon Miller (3), Amen Thompson (4), Ausar Thompson (5)

-- ============================================================
-- Historical spot check: 1969-70 season (Wilt Chamberlain era)
-- Wilt played for Los Angeles Lakers in 1969-70
-- ============================================================

SELECT player_name, team_name, SUM(pts) AS total_pts, AVG(pts) AS ppg,
       COUNT(*) AS games_played
FROM ZK_NBA.FLAT.player_box_basic
WHERE YEAR(game_date) = 1970
  AND player_name LIKE '%Chamberlain%'
GROUP BY player_name, team_name;
-- Expected: Wilt Chamberlain with Lakers data for the 1969-70 season

-- ============================================================
-- All-time most points in a single game (Wilt's 100-point game, 1962)
-- ============================================================

SELECT player_name, game_date, team_name, pts, reb, ast
FROM ZK_NBA.FLAT.player_box_basic
ORDER BY pts DESC
LIMIT 5;
-- Expected: Wilt Chamberlain's 100-point game (1962-03-02) should be #1

-- ============================================================
-- Team record check: all 30 teams present
-- ============================================================

SELECT COUNT(*) AS total_teams FROM ZK_NBA.FLAT.teams;
-- Expected: 30

SELECT abbreviation, full_name
FROM ZK_NBA.FLAT.teams
ORDER BY abbreviation;
-- Expected: All 30 current NBA teams
