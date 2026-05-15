-- Multi-player sanity check + final state confirmation.
USE ROLE DEVELOPER_ADMIN;
USE WAREHOUSE NBA_INGEST_WH;
USE DATABASE ZK_NBA;

-- Star players' 2024 season game counts (should all be ~70-100, not 140-200).
SELECT player_name, season, COUNT(*) AS games
FROM FLAT.player_box_basic
WHERE season IN (2024, 2025)
  AND player_id IN (
      '203999', -- Jokic
      '203507', -- Giannis
      '201939', -- Curry
      '2544',   -- LeBron
      '1628369', -- Tatum
      '1641705' -- Wembanyama (BR-only player)
  )
GROUP BY player_name, season
ORDER BY player_name, season;

-- Remaining duplicate check: any (player_id, game_date) with > 1 row?
SELECT 'remaining_dupes' AS check_name, COUNT(*) AS dupe_pairs
FROM (
    SELECT player_id, game_date, COUNT(*) AS row_count
    FROM FLAT.player_box_basic
    GROUP BY player_id, game_date
    HAVING COUNT(*) > 1
);

-- Total row count snapshot (post-dedup).
SELECT 'games'             AS tbl, COUNT(*) AS row_count FROM FLAT.games
UNION ALL SELECT 'player_box_basic',    COUNT(*) FROM FLAT.player_box_basic
UNION ALL SELECT 'player_box_advanced', COUNT(*) FROM FLAT.player_box_advanced
UNION ALL SELECT 'line_scores',         COUNT(*) FROM FLAT.line_scores
UNION ALL SELECT 'game_officials',      COUNT(*) FROM FLAT.game_officials
UNION ALL SELECT 'game_inactives',      COUNT(*) FROM FLAT.game_inactives
ORDER BY tbl;
