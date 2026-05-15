-- FLAT-table population audit. For each table grouped by source, report null
-- percentage per column. Anything >= 90% NULL is a likely bug pattern (vs
-- legitimately sparse data we'd see at 20-60%).
--
-- Reading the output:
--   pct values shown as decimals: 100.0 = 100% NULL = column is always empty.
--   "n/a" effectively means there's only one source so the breakdown collapses.

USE ROLE DEVELOPER_ADMIN;
USE WAREHOUSE NBA_INGEST_WH;
USE DATABASE ZK_NBA;

-- --------------------------------------------------------------------------
-- player_box_basic — known bug (team_id, team_abbr, season).
-- --------------------------------------------------------------------------
SELECT
    'player_box_basic'  AS tbl,
    source,
    COUNT(*)            AS total,
    ROUND(100.0 * (1 - COUNT(team_id)::FLOAT / COUNT(*)), 1) AS pct_null_team_id,
    ROUND(100.0 * (1 - COUNT(team_name)::FLOAT / COUNT(*)), 1) AS pct_null_team_name,
    ROUND(100.0 * (1 - COUNT(team_abbr)::FLOAT / COUNT(*)), 1) AS pct_null_team_abbr,
    ROUND(100.0 * (1 - COUNT(opponent_team_name)::FLOAT / COUNT(*)), 1) AS pct_null_opp_name,
    ROUND(100.0 * (1 - COUNT(season)::FLOAT / COUNT(*)), 1) AS pct_null_season,
    ROUND(100.0 * (1 - COUNT(game_type)::FLOAT / COUNT(*)), 1) AS pct_null_game_type,
    ROUND(100.0 * (1 - COUNT(player_name)::FLOAT / COUNT(*)), 1) AS pct_null_player_name,
    ROUND(100.0 * (1 - COUNT(minutes_played)::FLOAT / COUNT(*)), 1) AS pct_null_minutes,
    ROUND(100.0 * (1 - COUNT(plus_minus)::FLOAT / COUNT(*)), 1) AS pct_null_plus_minus,
    ROUND(100.0 * (1 - COUNT(br_player_slug)::FLOAT / COUNT(*)), 1) AS pct_null_br_slug
FROM FLAT.player_box_basic
GROUP BY source
ORDER BY source;

-- --------------------------------------------------------------------------
-- player_box_advanced — BR-only by design; verify population.
-- --------------------------------------------------------------------------
SELECT
    'player_box_advanced' AS tbl,
    COUNT(*) AS total,
    ROUND(100.0 * (1 - COUNT(player_id)::FLOAT / COUNT(*)), 1) AS pct_null_player_id,
    ROUND(100.0 * (1 - COUNT(ts_pct)::FLOAT / COUNT(*)), 1) AS pct_null_ts_pct,
    ROUND(100.0 * (1 - COUNT(usg_pct)::FLOAT / COUNT(*)), 1) AS pct_null_usg_pct,
    ROUND(100.0 * (1 - COUNT(bpm)::FLOAT / COUNT(*)), 1) AS pct_null_bpm,
    ROUND(100.0 * (1 - COUNT(br_player_slug)::FLOAT / COUNT(*)), 1) AS pct_null_br_slug
FROM FLAT.player_box_advanced;

-- --------------------------------------------------------------------------
-- games — already audited, repeat for completeness.
-- --------------------------------------------------------------------------
SELECT
    'games' AS tbl,
    source,
    COUNT(*) AS total,
    ROUND(100.0 * (1 - COUNT(home_team_id)::FLOAT / COUNT(*)), 1) AS pct_null_home_id,
    ROUND(100.0 * (1 - COUNT(away_team_id)::FLOAT / COUNT(*)), 1) AS pct_null_away_id,
    ROUND(100.0 * (1 - COUNT(season)::FLOAT / COUNT(*)), 1) AS pct_null_season,
    ROUND(100.0 * (1 - COUNT(season_id)::FLOAT / COUNT(*)), 1) AS pct_null_season_id,
    ROUND(100.0 * (1 - COUNT(home_plus_minus)::FLOAT / COUNT(*)), 1) AS pct_null_home_pm,
    ROUND(100.0 * (1 - COUNT(away_plus_minus)::FLOAT / COUNT(*)), 1) AS pct_null_away_pm
FROM FLAT.games
GROUP BY source
ORDER BY source;

-- --------------------------------------------------------------------------
-- line_scores — both pipelines.
-- --------------------------------------------------------------------------
SELECT
    'line_scores' AS tbl,
    source,
    COUNT(*) AS total,
    ROUND(100.0 * (1 - COUNT(home_team_abbr)::FLOAT / COUNT(*)), 1) AS pct_null_home_abbr,
    ROUND(100.0 * (1 - COUNT(away_team_abbr)::FLOAT / COUNT(*)), 1) AS pct_null_away_abbr,
    ROUND(100.0 * (1 - COUNT(home_q1)::FLOAT / COUNT(*)), 1) AS pct_null_q1,
    ROUND(100.0 * (1 - COUNT(home_q4)::FLOAT / COUNT(*)), 1) AS pct_null_q4,
    ROUND(100.0 * (1 - COUNT(home_pts)::FLOAT / COUNT(*)), 1) AS pct_null_home_pts
FROM FLAT.line_scores
GROUP BY source
ORDER BY source;

-- --------------------------------------------------------------------------
-- game_officials — Slice E recent work.
-- --------------------------------------------------------------------------
SELECT
    'game_officials' AS tbl,
    source_inferred,
    COUNT(*) AS total,
    ROUND(100.0 * (1 - COUNT(official_id)::FLOAT / COUNT(*)), 1) AS pct_null_official_id,
    ROUND(100.0 * (1 - COUNT(first_name)::FLOAT / COUNT(*)), 1) AS pct_null_first_name,
    ROUND(100.0 * (1 - COUNT(last_name)::FLOAT / COUNT(*)), 1) AS pct_null_last_name,
    ROUND(100.0 * (1 - COUNT(jersey_num)::FLOAT / COUNT(*)), 1) AS pct_null_jersey,
    ROUND(100.0 * (1 - COUNT(br_official_slug)::FLOAT / COUNT(*)), 1) AS pct_null_br_slug
FROM (
    SELECT *, CASE WHEN br_official_slug IS NOT NULL THEN 'br_scrape' ELSE 'jb_seed' END AS source_inferred
    FROM FLAT.game_officials
)
GROUP BY source_inferred
ORDER BY source_inferred;

-- --------------------------------------------------------------------------
-- game_inactives — Slice F recent work.
-- --------------------------------------------------------------------------
SELECT
    'game_inactives' AS tbl,
    source_inferred,
    COUNT(*) AS total,
    ROUND(100.0 * (1 - COUNT(player_id)::FLOAT / COUNT(*)), 1) AS pct_null_player_id,
    ROUND(100.0 * (1 - COUNT(team_id)::FLOAT / COUNT(*)), 1) AS pct_null_team_id,
    ROUND(100.0 * (1 - COUNT(team_abbr)::FLOAT / COUNT(*)), 1) AS pct_null_team_abbr,
    ROUND(100.0 * (1 - COUNT(jersey_num)::FLOAT / COUNT(*)), 1) AS pct_null_jersey,
    ROUND(100.0 * (1 - COUNT(br_player_slug)::FLOAT / COUNT(*)), 1) AS pct_null_br_slug
FROM (
    SELECT *, CASE WHEN br_player_slug IS NOT NULL THEN 'br_scrape' ELSE 'jb_seed' END AS source_inferred
    FROM FLAT.game_inactives
)
GROUP BY source_inferred
ORDER BY source_inferred;

-- --------------------------------------------------------------------------
-- players — JB only.
-- --------------------------------------------------------------------------
SELECT
    'players' AS tbl,
    COUNT(*) AS total,
    ROUND(100.0 * (1 - COUNT(birth_date)::FLOAT / COUNT(*)), 1) AS pct_null_birth_date,
    ROUND(100.0 * (1 - COUNT(college)::FLOAT / COUNT(*)), 1) AS pct_null_college,
    ROUND(100.0 * (1 - COUNT(country)::FLOAT / COUNT(*)), 1) AS pct_null_country,
    ROUND(100.0 * (1 - COUNT(height_in)::FLOAT / COUNT(*)), 1) AS pct_null_height,
    ROUND(100.0 * (1 - COUNT(weight_lb)::FLOAT / COUNT(*)), 1) AS pct_null_weight,
    ROUND(100.0 * (1 - COUNT(position)::FLOAT / COUNT(*)), 1) AS pct_null_position,
    ROUND(100.0 * (1 - COUNT(draft_year)::FLOAT / COUNT(*)), 1) AS pct_null_draft_year
FROM FLAT.players;

-- --------------------------------------------------------------------------
-- Does PLAYERSTATISTICS1 actually have a team_id column we could use?
-- (Determines whether the fix needs a name-lookup or just a column swap.)
-- --------------------------------------------------------------------------
SELECT COLUMN_NAME, DATA_TYPE
FROM JB_HISTORIC_NBA.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('PLAYERSTATISTICS1', 'PLAYERSTATISTICS2')
  AND (COLUMN_NAME ILIKE '%TEAM%' OR COLUMN_NAME ILIKE '%SEASON%')
ORDER BY TABLE_NAME, ORDINAL_POSITION;
