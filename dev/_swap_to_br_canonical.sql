-- Switch canonical source for season >= 2024 from JB to BR.
--
-- Why: BR rows have game_ids that join cleanly to games (which has BR rows
-- past Jun 2023). JB rows for season >= 2024 use NBA Stats game_ids that
-- don't exist in games. Picking BR-canonical resolves 3 of the 5 documented
-- limitations in one move.
--
-- Resulting eras:
--   Pre-2023-24 (season <= 2023): JB only, NBA Stats game_id format.
--   2023-24 onward (season >= 2024): BR only, BR slug format.
--
-- Run order:
--   Step 1: Pre-flight counts (don't proceed if BR coverage is incomplete).
--   Step 2: Recover the 65K BR rows we deleted in the earlier dedup.
--   Step 3: Delete JB rows for season >= 2024.
--   Step 4: Verify.

USE ROLE DEVELOPER_ADMIN;
USE WAREHOUSE NBA_INGEST_WH;
USE DATABASE ZK_NBA;

-- --------------------------------------------------------------------------
-- Step 1: Coverage pre-flight.
--   Compare JB and BR row counts per season for the swap window. If they
--   match (or BR is higher), BR coverage is complete and the swap is safe.
--   If JB has rows BR is missing, we'd lose data — bail and investigate.
-- --------------------------------------------------------------------------
WITH jb_pre AS (
    SELECT season, COUNT(*) AS jb_rows
    FROM FLAT.player_box_basic
    WHERE source = 'jb_seed' AND season >= 2024
    GROUP BY season
),
br_after AS (
    -- BR rows from before the dedup (time-travel) — represents the full
    -- BR coverage we'll restore in step 2.
    SELECT season, COUNT(*) AS br_rows
    FROM FLAT.player_box_basic AT(OFFSET => -4500)
    WHERE source = 'br_scrape' AND season >= 2024
    GROUP BY season
)
SELECT
    COALESCE(jb_pre.season, br_after.season) AS season,
    COALESCE(jb_rows, 0) AS jb_rows,
    COALESCE(br_rows, 0) AS br_rows,
    COALESCE(br_rows, 0) - COALESCE(jb_rows, 0) AS br_minus_jb
FROM jb_pre FULL OUTER JOIN br_after USING (season)
ORDER BY season;

-- --------------------------------------------------------------------------
-- Step 2: Restore the 65K BR rows the earlier dedup deleted.
-- These already had team_id populated from the backfill, so no further
-- resolution needed.
-- --------------------------------------------------------------------------
INSERT INTO FLAT.player_box_basic
SELECT old.*
FROM FLAT.player_box_basic AT(OFFSET => -4500) old
WHERE old.source = 'br_scrape'
  AND old.season >= 2024
  AND NOT EXISTS (
      SELECT 1 FROM FLAT.player_box_basic curr
      WHERE curr.game_id = old.game_id
        AND curr.player_id = old.player_id
        AND curr.source = 'br_scrape'
  );

-- --------------------------------------------------------------------------
-- Step 3: Delete JB rows for season >= 2024.
-- Clean cut: BR is now the only source for 2023-24 onward.
-- --------------------------------------------------------------------------
DELETE FROM FLAT.player_box_basic
WHERE source = 'jb_seed' AND season >= 2024;

-- --------------------------------------------------------------------------
-- Step 4: Verify.
-- --------------------------------------------------------------------------
-- Final row counts per source.
SELECT source, COUNT(*) AS row_count, MIN(game_date) AS min_date, MAX(game_date) AS max_date
FROM FLAT.player_box_basic
GROUP BY source ORDER BY source;

-- Per-season distribution (sanity: no dupes, expected game counts).
SELECT season, source, COUNT(*) AS row_count
FROM FLAT.player_box_basic
WHERE season >= 2022
GROUP BY season, source
ORDER BY season, source;

-- Jokic: should now show ~91/85/71 with single source per season.
SELECT season, source, COUNT(*) AS games, ROUND(AVG(pts), 1) AS avg_pts
FROM FLAT.player_box_basic
WHERE player_id = '203999'
GROUP BY season, source ORDER BY season, source;

-- Cross-table join sanity: every player_box row should now have a
-- matching games row for season >= 2024.
SELECT
    'pbb_with_matching_games' AS check_name,
    COUNT(*) AS pbb_rows,
    COUNT(g.game_id) AS rows_with_game_match
FROM FLAT.player_box_basic pbb
LEFT JOIN FLAT.games g ON g.game_id = pbb.game_id
WHERE pbb.season >= 2024;
