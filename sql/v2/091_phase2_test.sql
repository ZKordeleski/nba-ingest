-- Phase 2 success test — WRITTEN BEFORE THE FULL RUN (test-first).
-- Run after the all-teams 2024-25 load:
--   .venv/bin/python dev/apply_sql.py sql/v2/091_phase2_test.sql
-- Every row is an assertion; Phase 2 succeeds only when all show passed=TRUE.
-- The headline is #3: the 2025 NBA Finals are present and labeled round='Finals'
-- (the literal query that started the rebuild).

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

WITH
teams AS (
    SELECT home_team_abbr AS abbr FROM games
    UNION SELECT away_team_abbr FROM games
),
team_pts AS (
    SELECT game_id, team_abbr, SUM(pts) AS s FROM player_box_basic GROUP BY 1, 2
),
recon AS (
    SELECT COUNT(*) AS m FROM team_pts tp JOIN games g ON tp.game_id = g.game_id
    WHERE tp.s <> CASE WHEN tp.team_abbr = g.home_team_abbr THEN g.home_pts
                       WHEN tp.team_abbr = g.away_team_abbr THEN g.away_pts END
),
v1 AS (SELECT COUNT(DISTINCT game_id) AS n FROM ZK_NBA.FLAT.games WHERE season = 2025)
SELECT * FROM (
    SELECT 1 AS ord, 'full-season game count (~1316)' AS check_name,
           (SELECT COUNT(*) FROM games) BETWEEN 1280 AND 1340 AS passed,
           'games=' || (SELECT COUNT(*) FROM games) AS detail
    UNION ALL SELECT 2, 'all 30 teams present',
           (SELECT COUNT(*) FROM teams) = 30, 'teams=' || (SELECT COUNT(*) FROM teams)
    UNION ALL SELECT 3, '*** 2025 NBA Finals present + labeled round=Finals (7 games) ***',
           (SELECT COUNT(*) FROM games WHERE round = 'Finals') = 7
           AND (SELECT COUNT(*) FROM games WHERE round = 'Finals' AND season_type <> 'Playoffs') = 0,
           'finals_games=' || (SELECT COUNT(*) FROM games WHERE round = 'Finals')
    UNION ALL SELECT 4, 'all canonical playoff rounds present',
           (SELECT COUNT(DISTINCT round) FROM games
              WHERE round IN ('First Round','Conference Semifinals','Conference Finals','Finals')) = 4,
           'rounds=' || (SELECT LISTAGG(DISTINCT round, ', ') FROM games WHERE round IS NOT NULL)
    UNION ALL SELECT 5, 'no playoff game mislabeled Regular Season',
           (SELECT COUNT(*) FROM games WHERE round IS NOT NULL AND season_type NOT IN ('Playoffs','Play-In')) = 0,
           'mislabeled=' || (SELECT COUNT(*) FROM games WHERE round IS NOT NULL AND season_type NOT IN ('Playoffs','Play-In'))
    UNION ALL SELECT 6, 'domain guard clean (ties/made<=att/pct/range)',
           (SELECT COUNT(*) FROM games WHERE home_pts = away_pts) = 0
           AND (SELECT COUNT(*) FROM player_box_basic WHERE fgm>fga OR fg3m>fg3a OR ftm>fta
                  OR pts<0 OR pts>105 OR fg_pct<0 OR fg_pct>1) = 0,
           'ties=' || (SELECT COUNT(*) FROM games WHERE home_pts=away_pts)
           || ' rowviol=' || (SELECT COUNT(*) FROM player_box_basic WHERE fgm>fga OR fg3m>fg3a OR ftm>fta OR pts<0 OR pts>105 OR fg_pct<0 OR fg_pct>1)
    UNION ALL SELECT 7, 'team box totals reconcile to player-pts sum',
           (SELECT m FROM recon) = 0, 'mismatched=' || (SELECT m FROM recon)
    UNION ALL SELECT 8, 'officials loaded for most games',
           (SELECT COUNT(DISTINCT game_id) FROM game_officials) > 1000,
           'games_with_officials=' || (SELECT COUNT(DISTINCT game_id) FROM game_officials)
    UNION ALL SELECT 9, 'inactives loaded',
           (SELECT COUNT(*) FROM game_inactives) > 0,
           'inactive_rows=' || (SELECT COUNT(*) FROM game_inactives)
    UNION ALL SELECT 10, 'parity vs V1 ZK_NBA season=2025 (within 3%)',
           ABS((SELECT COUNT(*) FROM games) - (SELECT n FROM v1)) <= GREATEST(30, (SELECT n FROM v1) * 0.03),
           'v2=' || (SELECT COUNT(*) FROM games) || ' v1=' || (SELECT n FROM v1)
    UNION ALL SELECT 11, 'metric_coverage intact (>=17, grows as boundaries are found)',
           (SELECT COUNT(*) FROM metric_coverage) >= 17, 'rows=' || (SELECT COUNT(*) FROM metric_coverage)
    UNION ALL SELECT 12, 'quarantine rate low (<30)',
           (SELECT COUNT(*) FROM quarantine) < 30, 'quarantined=' || (SELECT COUNT(*) FROM quarantine)
)
ORDER BY ord;
