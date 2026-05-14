-- Slice 1 validation: referential integrity checks.
-- These catch orphaned FK references and duplicate natural keys.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- ============================================================
-- 1. No orphaned official assignments
-- ============================================================
-- Note: OFFICIALS covers modern games only; GAME only goes to Jun 2023.
-- Some officials assignments may reference games NOT in FLAT.games (post-Jun 2023
-- games that are in JB OFFICIALS but not yet in FLAT.games until Slice 2 fills them).
-- Run again after Slice 2 for a clean zero.

SELECT COUNT(*) AS orphaned_official_assignments
FROM ZK_NBA.FLAT.game_officials o
LEFT JOIN ZK_NBA.FLAT.games g ON o.game_id = g.game_id
WHERE g.game_id IS NULL;
-- Expected after Slice 1: some non-zero number (officials may cover games post-Jun 2023)
-- Expected after Slice 2: 0

-- ============================================================
-- 2. No orphaned inactive player assignments
-- ============================================================
SELECT COUNT(*) AS orphaned_inactive_assignments
FROM ZK_NBA.FLAT.game_inactives i
LEFT JOIN ZK_NBA.FLAT.games g ON i.game_id = g.game_id
WHERE g.game_id IS NULL;
-- Expected after Slice 1: some non-zero (same reasoning as officials)
-- Expected after Slice 2: 0

-- ============================================================
-- 3. No orphaned player box rows (player_box -> games)
-- ============================================================
SELECT COUNT(*) AS orphaned_player_box_rows
FROM ZK_NBA.FLAT.player_box_basic pb
LEFT JOIN ZK_NBA.FLAT.games g ON pb.game_id = g.game_id
WHERE g.game_id IS NULL;
-- Expected: some non-zero (PLAYERSTATISTICS1 covers 2001-2025; GAME only to Jun 2023)
-- The 2023-2025 player rows are expected orphans until Slice 2 fills FLAT.games.
-- This count should be close to: rows for games after 2023-06-12

-- Count orphaned player-box rows by year to understand the scope
SELECT YEAR(pb.game_date) AS yr, COUNT(*) AS orphaned_rows
FROM ZK_NBA.FLAT.player_box_basic pb
LEFT JOIN ZK_NBA.FLAT.games g ON pb.game_id = g.game_id
WHERE g.game_id IS NULL
GROUP BY 1
ORDER BY 1;
-- Expected: rows only for 2023 (second half), 2024, 2025

-- ============================================================
-- 4. No duplicate (game_id, player_id) in player_box_basic
-- ============================================================
SELECT COUNT(*) AS duplicate_player_game_pairs
FROM (
    SELECT game_id, player_id, COUNT(*) AS n
    FROM ZK_NBA.FLAT.player_box_basic
    GROUP BY game_id, player_id
    HAVING n > 1
);
-- Expected: 0
-- If non-zero, investigate UNION boundary at 2001-12-30.

-- Show any duplicates if they exist
SELECT game_id, player_id, COUNT(*) AS n
FROM ZK_NBA.FLAT.player_box_basic
GROUP BY game_id, player_id
HAVING n > 1
ORDER BY n DESC
LIMIT 10;

-- ============================================================
-- 5. All 30 current teams present in FLAT.teams
-- ============================================================
SELECT COUNT(*) AS total_teams FROM ZK_NBA.FLAT.teams;
-- Expected: 30

-- Check the 5 teams that were missing from JB TEAM_DETAILS
SELECT abbreviation, full_name, arena, head_coach
FROM ZK_NBA.FLAT.teams
WHERE abbreviation IN ('ORL', 'NYK', 'BOS', 'CLE', 'NOP')
ORDER BY abbreviation;
-- Expected: 5 rows. arena/head_coach NULL until manually filled from BR.

-- ============================================================
-- 6. PBP deduplication: UNION correctly removed the 1 duplicate game
-- ============================================================
-- After seeding, check that the overlapping game appears exactly once
WITH game_counts AS (
    SELECT game_id, COUNT(*) AS event_count
    FROM ZK_NBA.FLAT.play_by_play
    GROUP BY game_id
)
SELECT COUNT(*) AS games_with_multiple_event_sets
FROM (
    -- A game duplicated via UNION ALL would show roughly 2x events
    -- This checks no game has a suspiciously high event count
    SELECT game_id FROM game_counts WHERE event_count > 700  -- 700 events per game is very high
);
-- Expected: 0 or a small number of genuinely long games

-- ============================================================
-- 7. Line scores sum check: home_q1+q2+q3+q4+OTs should equal home_pts
-- ============================================================
SELECT COUNT(*) AS pts_sum_mismatches
FROM ZK_NBA.FLAT.line_scores
WHERE (COALESCE(home_q1, 0) + COALESCE(home_q2, 0) + COALESCE(home_q3, 0) + COALESCE(home_q4, 0)
       + COALESCE(home_ot1, 0) + COALESCE(home_ot2, 0) + COALESCE(home_ot3, 0) + COALESCE(home_ot4, 0))
      != home_pts;
-- Expected: 0 (quarter scores should sum to total; if non-zero, casting issue)
