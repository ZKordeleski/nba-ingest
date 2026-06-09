-- Phase 3 success test — WRITTEN BEFORE THE 1972-73 LOAD (test-first).
-- Stress-tests historical-era handling. Run after loading season=1973:
--   .venv/bin/python dev/apply_sql.py sql/v2/092_phase3_test.sql
-- Headline: #2 (NULL discipline at scale — a 1972-73 steal is NULL, never 0)
-- and #8 (both eras coexist correctly in one schema).

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

WITH
g73 AS (SELECT * FROM games WHERE season = 1973),
tp AS (SELECT game_id, team_abbr, SUM(pts) s FROM player_box_basic WHERE season = 1973 GROUP BY 1,2),
recon AS (SELECT COUNT(*) m FROM tp JOIN g73 g ON tp.game_id = g.game_id
          WHERE tp.s <> CASE WHEN tp.team_abbr = g.home_team_abbr THEN g.home_pts
                             WHEN tp.team_abbr = g.away_team_abbr THEN g.away_pts END)
SELECT * FROM (
    SELECT 1 AS ord, '1972-73 game count (~738)' AS check_name,
           (SELECT COUNT(*) FROM g73) BETWEEN 700 AND 760 AS passed,
           'games=' || (SELECT COUNT(*) FROM g73) AS detail

    -- *** Ramp, not cliff: stl/blk/tov are SPARSE but real in 1972-73 (BR partial
    -- data), plausible, and never fabricated. NULL discipline holds (no coerced 0). ***
    UNION ALL SELECT 2, '*** 1972-73 stl/blk/tov a SPARSE RAMP (real partial data), plausible ***',
           (SELECT COUNT(*) FROM player_box_basic WHERE season=1973 AND stl IS NOT NULL) * 100.0
                / (SELECT COUNT(*) FROM player_box_basic WHERE season=1973) < 5
           AND (SELECT COALESCE(MAX(stl),0) FROM player_box_basic WHERE season=1973) <= 15
           AND (SELECT COALESCE(MAX(blk),0) FROM player_box_basic WHERE season=1973) <= 20
           AND (SELECT COALESCE(MAX(tov),0) FROM player_box_basic WHERE season=1973) <= 15,
           'stl_present=' || (SELECT COUNT(*) FROM player_box_basic WHERE season=1973 AND stl IS NOT NULL)
           || ' max(stl/blk/tov)=' || (SELECT MAX(stl) FROM player_box_basic WHERE season=1973)
           || '/' || (SELECT MAX(blk) FROM player_box_basic WHERE season=1973)
           || '/' || (SELECT MAX(tov) FROM player_box_basic WHERE season=1973)
    UNION ALL SELECT 3, 'no 1972-73 3-pointers (line did not exist until 1979-80)',
           (SELECT COUNT(*) FROM player_box_basic WHERE season = 1973 AND fg3m IS NOT NULL) = 0,
           'fg3_rows=' || (SELECT COUNT(*) FROM player_box_basic WHERE season = 1973 AND fg3m IS NOT NULL)
    UNION ALL SELECT 4, 'tracked stats present in 1972-73 (pts ~100%, total reb >=99%)',
           (SELECT COUNT(*) FROM player_box_basic WHERE season=1973 AND pts IS NOT NULL) > 5000
           AND (SELECT COUNT(*) FROM player_box_basic WHERE season=1973 AND pts IS NOT NULL AND reb IS NULL) * 100.0
                / (SELECT COUNT(*) FROM player_box_basic WHERE season=1973 AND pts IS NOT NULL) < 1,
           'played=' || (SELECT COUNT(*) FROM player_box_basic WHERE season=1973 AND pts IS NOT NULL)
           || ' reb_null=' || (SELECT COUNT(*) FROM player_box_basic WHERE season=1973 AND pts IS NOT NULL AND reb IS NULL)

    -- old-era playoff round handling
    UNION ALL SELECT 5, '1973 playoffs present incl. round=Finals (NYK champs)',
           (SELECT COUNT(*) FROM g73 WHERE round = 'Finals') > 0,
           'finals_games=' || (SELECT COUNT(*) FROM g73 WHERE round = 'Finals')
           || ' rounds=' || (SELECT LISTAGG(DISTINCT round, ', ') FROM g73 WHERE round IS NOT NULL)

    -- guard + integrity hold on old data
    UNION ALL SELECT 6, 'domain guard clean for 1972-73',
           (SELECT COUNT(*) FROM g73 WHERE home_pts = away_pts) = 0
           AND (SELECT COUNT(*) FROM player_box_basic WHERE season=1973 AND (fgm>fga OR ftm>fta OR pts<0 OR pts>105 OR fg_pct<0 OR fg_pct>1)) = 0,
           'rowviol=' || (SELECT COUNT(*) FROM player_box_basic WHERE season=1973 AND (fgm>fga OR ftm>fta OR pts<0 OR pts>105 OR fg_pct<0 OR fg_pct>1))
    UNION ALL SELECT 7, 'team box totals reconcile (1972-73)',
           (SELECT m FROM recon) = 0, 'mismatched=' || (SELECT m FROM recon)
    UNION ALL SELECT 8, 'is_starter works on old table format (both values present)',
           (SELECT COUNT(DISTINCT is_starter) FROM player_box_basic WHERE season=1973) = 2,
           'distinct_is_starter=' || (SELECT COUNT(DISTINCT is_starter) FROM player_box_basic WHERE season=1973)

    -- *** both eras coexist correctly in ONE schema ***
    UNION ALL SELECT 9, '*** both eras in one schema: 2025 stl DENSE, 1973 stl SPARSE (ramp) ***',
           (SELECT COUNT(*) FROM player_box_basic WHERE season=2025 AND stl IS NOT NULL) > 5000
           AND (SELECT COUNT(*) FROM player_box_basic WHERE season=1973 AND stl IS NOT NULL) * 100.0
                / (SELECT COUNT(*) FROM player_box_basic WHERE season=1973) < 5,
           '2025_stl=' || (SELECT COUNT(*) FROM player_box_basic WHERE season=2025 AND stl IS NOT NULL)
           || ' 1973_stl=' || (SELECT COUNT(*) FROM player_box_basic WHERE season=1973 AND stl IS NOT NULL)
    UNION ALL SELECT 10, 'officials honestly sparse pre-1995 (documented in metric_coverage)',
           (SELECT COUNT(*) FROM game_officials go JOIN g73 g ON go.game_id=g.game_id) = 0
           AND (SELECT COUNT(*) FROM metric_coverage WHERE metric='game_officials') = 1,
           'officials_1973=' || (SELECT COUNT(*) FROM game_officials go JOIN g73 g ON go.game_id=g.game_id)
)
ORDER BY ord;
