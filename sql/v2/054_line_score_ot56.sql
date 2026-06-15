-- Extend line_scores to the NBA all-time overtime maximum (2026-06-14).
--
-- The model capped at 4 OT (home_ot1..ot4), silently truncating the only two 5+OT
-- games in NBA history: the 5-OT Bucks-Sonics (1989, 198911090MIL) and the 6-OT
-- Indianapolis-Rochester game (1951, the longest ever). 6 OT is the all-time max in
-- 79 seasons, so ot5/ot6 makes the wide model COMPLETE for NBA history.
-- (A more robust period-normalized model is a tracked backlog item; this unblocks now.)
--
--   .venv/bin/python dev/apply_sql.py sql/v2/054_line_score_ot56.sql

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

ALTER TABLE line_scores ADD COLUMN IF NOT EXISTS home_ot5 INT COMMENT '5th overtime (rare: 1989 5-OT game).';
ALTER TABLE line_scores ADD COLUMN IF NOT EXISTS home_ot6 INT COMMENT '6th overtime (NBA all-time max: 1951 INO-ROC).';
ALTER TABLE line_scores ADD COLUMN IF NOT EXISTS away_ot5 INT COMMENT '5th overtime.';
ALTER TABLE line_scores ADD COLUMN IF NOT EXISTS away_ot6 INT COMMENT '6th overtime.';
