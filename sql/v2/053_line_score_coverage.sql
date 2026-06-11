-- Line-score quarter completeness as a COVERAGE fact (2026-06-11).
--
-- BR's early-era line scores are incomplete: Q1/Q2 (or the whole line-score table)
-- are often absent pre-1950s, while the game TOTAL is authoritative. This is the same
-- kind of era-coverage ramp as stl/blk sparse pre-1974 — a NULL quarter is NOT
-- recorded, never 0. We record it here so absence is documented + agent-visible, and
-- the audit's line-score completeness detector is coverage-aware (era ramp expected;
-- incompleteness in an otherwise-complete season is the anomaly that flags).
--
--   .venv/bin/python dev/apply_sql.py sql/v2/053_line_score_coverage.sql

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

DELETE FROM metric_coverage WHERE metric = 'line_score_quarters';
INSERT INTO metric_coverage (metric, column_ref, first_tracked_season, status, null_means, authority) VALUES
    ('line_score_quarters', 'line_scores.home_q1..away_q4', NULL, 'recording_ramp',
     'Quarter-by-quarter scores are incomplete in early eras (esp. BAA / pre-1950s): BR omits Q1/Q2 or the whole line-score table for many old games. A NULL quarter is NOT recorded, never 0; the game total is authoritative. Completeness ramps to ~full in the modern era.',
     'BR line-score completeness ramp (2026-06-11 BAA evidence)');
