-- Revised dedup: JB games table doesn't extend to overlap years, so we can't
-- map BR game_ids to JB game_ids. Instead, dedup directly by (player_id,
-- game_date). For each player-date where both JB and BR rows exist, the BR
-- row is the duplicate.
--
-- Tables affected: only player_box_basic. The other tables (games,
-- line_scores, game_officials, game_inactives) have JB rows only through
-- 2023-06-12, so 2023-24+ overlap doesn't apply to them.

USE ROLE DEVELOPER_ADMIN;
USE WAREHOUSE NBA_INGEST_WH;
USE DATABASE ZK_NBA;

-- First confirm scope: how many BR player_box rows have a matching JB
-- (player_id, game_date)?
SELECT COUNT(*) AS br_rows_duplicating_jb
FROM FLAT.player_box_basic pbb_br
WHERE pbb_br.source = 'br_scrape'
  AND EXISTS (
      SELECT 1 FROM FLAT.player_box_basic pbb_jb
      WHERE pbb_jb.source = 'jb_seed'
        AND pbb_jb.player_id = pbb_br.player_id
        AND pbb_jb.game_date = pbb_br.game_date
  );

-- Confirm scope on game_officials and game_inactives too.
SELECT 'game_officials br dups' AS check_name, COUNT(*) AS row_count
FROM FLAT.game_officials go_br
WHERE go_br.br_official_slug IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM FLAT.game_officials go_jb
      WHERE go_jb.br_official_slug IS NULL
        AND go_jb.official_id = go_br.official_id
        -- we need game_date to match but officials has no date column;
        -- inferring via game_id won't work due to format mismatch.
        -- This counts officials present in both sources without date filter.
  );

-- Apply the dedup.
DELETE FROM FLAT.player_box_basic pbb
WHERE pbb.source = 'br_scrape'
  AND EXISTS (
      SELECT 1 FROM FLAT.player_box_basic pbb_jb
      WHERE pbb_jb.source = 'jb_seed'
        AND pbb_jb.player_id = pbb.player_id
        AND pbb_jb.game_date = pbb.game_date
  );

-- Verify: Jokic 2024 should now be ~100 games, 2025 ~80.
SELECT
    season,
    COUNT(*) AS games,
    ROUND(AVG(pts), 1)  AS avg_pts,
    ROUND(AVG(ast), 1)  AS avg_ast,
    ROUND(AVG(reb), 1)  AS avg_reb
FROM FLAT.player_box_basic
WHERE player_id = '203999'
GROUP BY season ORDER BY season;

-- Confirm row totals.
SELECT source, COUNT(*) AS row_count
FROM FLAT.player_box_basic
GROUP BY source
ORDER BY source;
