-- Phase 1 success test — WRITTEN BEFORE THE BUILD (test-first contract).
-- Run AFTER the DEN 2024-25 slice is loaded:
--   .venv/bin/python dev/apply_sql.py sql/v2/090_phase1_test.sql
--
-- Every row is an assertion: passed=TRUE means that criterion holds. Phase 1 is
-- successful only when every row shows passed=TRUE. The last block is the
-- basketball-truth spot-check — the check a fan would recognize, and the one the
-- V1 database fails.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

WITH
den_games AS (
    SELECT * FROM games
    WHERE season = 2025 AND (home_team_abbr = 'DEN' OR away_team_abbr = 'DEN')
),
-- per (game, team) player-points sums, to reconcile against the team box total
team_pts AS (
    SELECT b.game_id, b.team_abbr, SUM(b.pts) AS player_pts_sum
    FROM player_box_basic b
    JOIN den_games g ON b.game_id = g.game_id
    GROUP BY 1, 2
),
recon AS (
    SELECT COUNT(*) AS mismatches
    FROM team_pts tp
    JOIN den_games g ON tp.game_id = g.game_id
    WHERE tp.player_pts_sum <> CASE WHEN tp.team_abbr = g.home_team_abbr THEN g.home_pts
                                    WHEN tp.team_abbr = g.away_team_abbr THEN g.away_pts END
)
SELECT * FROM (
    -- ── coverage / schema ────────────────────────────────────────────────
    SELECT 1 AS ord, 'metric_coverage seeded' AS check,
           (SELECT COUNT(*) FROM metric_coverage) >= 17 AS passed,
           'rows=' || (SELECT COUNT(*) FROM metric_coverage) AS detail

    -- ── load completeness ────────────────────────────────────────────────
    UNION ALL SELECT 2, 'DEN regular-season game count ~82',
           (SELECT COUNT(*) FROM den_games WHERE season_type = 'Regular Season') BETWEEN 80 AND 84,
           'reg_games=' || (SELECT COUNT(*) FROM den_games WHERE season_type = 'Regular Season')
    UNION ALL SELECT 3, 'DEN playoff games loaded',
           (SELECT COUNT(*) FROM den_games WHERE season_type = 'Playoffs') > 0,
           'playoff_games=' || (SELECT COUNT(*) FROM den_games WHERE season_type = 'Playoffs')
    UNION ALL SELECT 4, 'player_box rows loaded for DEN games',
           (SELECT COUNT(*) FROM player_box_basic b JOIN den_games g ON b.game_id = g.game_id) > 200,
           'box_rows=' || (SELECT COUNT(*) FROM player_box_basic b JOIN den_games g ON b.game_id = g.game_id)

    -- ── single-source invariant (no impersonation) ───────────────────────
    UNION ALL SELECT 5, 'all game_id are BR slugs (no NBA-numeric)',
           (SELECT COUNT(*) FROM den_games WHERE NOT game_id RLIKE '^[0-9]{8}0[A-Z]{3}$') = 0,
           'non_slug_ids=' || (SELECT COUNT(*) FROM den_games WHERE NOT game_id RLIKE '^[0-9]{8}0[A-Z]{3}$')

    -- ── domain guard, evaluated on loaded data (expect 0 violations) ──────
    UNION ALL SELECT 6, 'no tie games (home_pts <> away_pts)',
           (SELECT COUNT(*) FROM den_games WHERE home_pts = away_pts) = 0,
           'ties=' || (SELECT COUNT(*) FROM den_games WHERE home_pts = away_pts)
    UNION ALL SELECT 7, 'made <= attempted (fg/fg3/ft)',
           (SELECT COUNT(*) FROM player_box_basic WHERE fgm > fga OR fg3m > fg3a OR ftm > fta) = 0,
           'violations=' || (SELECT COUNT(*) FROM player_box_basic WHERE fgm > fga OR fg3m > fg3a OR ftm > fta)
    UNION ALL SELECT 8, 'fg_pct within [0,1]',
           (SELECT COUNT(*) FROM player_box_basic WHERE fg_pct < 0 OR fg_pct > 1) = 0,
           'violations=' || (SELECT COUNT(*) FROM player_box_basic WHERE fg_pct < 0 OR fg_pct > 1)
    UNION ALL SELECT 9, 'player pts within [0,105]',
           (SELECT COUNT(*) FROM player_box_basic WHERE pts < 0 OR pts > 105) = 0,
           'violations=' || (SELECT COUNT(*) FROM player_box_basic WHERE pts < 0 OR pts > 105)

    -- ── NULL discipline: modern stats must NOT be null for players who played ─
    UNION ALL SELECT 10, 'modern (2025) stl recorded for players who played',
           (SELECT COUNT(*) FROM player_box_basic WHERE season = 2025 AND minutes_played > 0 AND stl IS NULL) = 0,
           'null_stl_played=' || (SELECT COUNT(*) FROM player_box_basic WHERE season = 2025 AND minutes_played > 0 AND stl IS NULL)

    -- ══ BASKETBALL-TRUTH SPOT-CHECKS (the checks V1 fails) ═════════════════
    UNION ALL SELECT 11, 'every playoff game has a canonical round + game_in_series',
           (SELECT COUNT(*) FROM den_games
              WHERE season_type = 'Playoffs'
                AND (round NOT IN ('First Round','Conference Semifinals','Conference Finals','Finals','Play-In')
                     OR round IS NULL OR game_in_series NOT BETWEEN 1 AND 7)) = 0
           AND (SELECT COUNT(*) FROM den_games WHERE season_type = 'Playoffs') > 0,
           'rounds=' || (SELECT LISTAGG(DISTINCT round, ', ') FROM den_games WHERE season_type = 'Playoffs')
    UNION ALL SELECT 12, 'no playoff game mislabeled Regular Season (the FINALS-class fix)',
           (SELECT COUNT(*) FROM den_games WHERE round IS NOT NULL AND season_type <> 'Playoffs') = 0,
           'mislabeled=' || (SELECT COUNT(*) FROM den_games WHERE round IS NOT NULL AND season_type <> 'Playoffs')
    UNION ALL SELECT 13, 'Jokic recorded a triple-double for DEN in 2024-25',
           (SELECT COUNT(*) FROM player_box_basic
              WHERE team_abbr = 'DEN' AND player_name ILIKE '%joki%'
                AND pts >= 10 AND reb >= 10 AND ast >= 10) > 0,
           'jokic_triple_doubles=' || (SELECT COUNT(*) FROM player_box_basic
              WHERE team_abbr = 'DEN' AND player_name ILIKE '%joki%'
                AND pts >= 10 AND reb >= 10 AND ast >= 10)
    UNION ALL SELECT 14, 'team box totals reconcile to player-pts sum',
           (SELECT mismatches FROM recon) = 0,
           'mismatched_team_games=' || (SELECT mismatches FROM recon)
)
ORDER BY ord;
