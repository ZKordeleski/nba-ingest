-- Slice 1 validation: row counts.
-- Run after all 050_seed_from_jb/*.sql files have completed.
-- Compare actual counts against expected values in the comments.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

SELECT 'player_box_basic'  AS table_name, COUNT(*) AS row_count FROM ZK_NBA.FLAT.player_box_basic
UNION ALL SELECT 'games',          COUNT(*) FROM ZK_NBA.FLAT.games
UNION ALL SELECT 'line_scores',    COUNT(*) FROM ZK_NBA.FLAT.line_scores
UNION ALL SELECT 'game_officials', COUNT(*) FROM ZK_NBA.FLAT.game_officials
UNION ALL SELECT 'game_inactives', COUNT(*) FROM ZK_NBA.FLAT.game_inactives
UNION ALL SELECT 'players',        COUNT(*) FROM ZK_NBA.FLAT.players
UNION ALL SELECT 'teams',          COUNT(*) FROM ZK_NBA.FLAT.teams
UNION ALL SELECT 'team_history',   COUNT(*) FROM ZK_NBA.FLAT.team_history
UNION ALL SELECT 'draft',          COUNT(*) FROM ZK_NBA.FLAT.draft
UNION ALL SELECT 'draft_combine',  COUNT(*) FROM ZK_NBA.FLAT.draft_combine
UNION ALL SELECT 'play_by_play',   COUNT(*) FROM ZK_NBA.FLAT.play_by_play
ORDER BY 1;

-- Expected:
--   draft             ~7,990
--   draft_combine     ~1,202
--   game_inactives    ~110,191
--   game_officials    ~70,971
--   games             ~65,642
--   line_scores       ~58,053
--   play_by_play      ~2,416,773
--   player_box_basic  ~1,623,343
--   players           ~6,533
--   team_history      ~140
--   teams             30  (exact)
