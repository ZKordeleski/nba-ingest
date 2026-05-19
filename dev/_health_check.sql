-- Health check 4 days after the team-id fix + canonical-swap shipped.
-- What we want to verify:
--   1. Daily cron has been adding rows (4 mornings of games settled).
--   2. New BR rows have team_id resolved (no regression on our fix).
--   3. No new edge case duplicates or weirdness.

USE ROLE DEVELOPER_ADMIN;
USE WAREHOUSE NBA_INGEST_WH;
USE DATABASE ZK_NBA;

-- 1) Most recent game_date + fetched_at per source. Tells us if cron is running.
SELECT
    source,
    COUNT(*) AS row_count,
    MAX(game_date) AS latest_game,
    MAX(fetched_at) AS latest_write
FROM FLAT.player_box_basic
GROUP BY source
ORDER BY source;

-- 2) Rows added in last 4 days (since 2026-05-15) — did cron write them?
SELECT
    DATE(fetched_at) AS write_date,
    COUNT(*) AS rows_written,
    COUNT(DISTINCT game_id) AS games_written,
    SUM(CASE WHEN team_id IS NULL THEN 1 ELSE 0 END) AS null_team_id,
    SUM(CASE WHEN team_name IS NULL THEN 1 ELSE 0 END) AS null_team_name,
    SUM(CASE WHEN opponent_team_name IS NULL THEN 1 ELSE 0 END) AS null_opp_name,
    SUM(CASE WHEN season IS NULL THEN 1 ELSE 0 END) AS null_season
FROM FLAT.player_box_basic
WHERE fetched_at >= '2026-05-15'
GROUP BY DATE(fetched_at)
ORDER BY write_date;

-- 3) Games added since the fix shipped.
SELECT
    DATE(fetched_at) AS write_date,
    COUNT(*) AS games,
    SUM(CASE WHEN home_team_id IS NULL THEN 1 ELSE 0 END) AS null_home_id,
    SUM(CASE WHEN home_plus_minus IS NULL THEN 1 ELSE 0 END) AS null_home_pm
FROM FLAT.games
WHERE fetched_at >= '2026-05-15'
GROUP BY DATE(fetched_at)
ORDER BY write_date;

-- 4) Most recent settled game — drill in to confirm it's a clean row.
SELECT
    game_id, game_date, season, season_id, season_type,
    home_team_id, home_team_abbr, away_team_id, away_team_abbr,
    home_pts, away_pts, home_plus_minus
FROM FLAT.games
WHERE source = 'br_scrape'
ORDER BY game_date DESC, fetched_at DESC
LIMIT 3;

-- 5) Has the canonical-swap boundary stayed clean? No JB rows post-2023.
SELECT source, season, COUNT(*) AS row_count
FROM FLAT.player_box_basic
WHERE season >= 2023
GROUP BY source, season
ORDER BY season, source;
