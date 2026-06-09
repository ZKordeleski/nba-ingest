-- ZK_NBA_V2 DERIVED views — the consumption layer that makes metric_coverage
-- load-bearing rather than decorative.
--
-- A view is read-only: it cannot touch or corrupt FLAT data. This is ONE worked
-- example (not a full leaderboard layer) proving the no-ambiguous-NULL invariant
-- at the *answer* layer, where the original "Bill Russell had 0 steals" failure
-- actually lives. More guardrail views get added when a query class needs one.
--
-- Run after the FLAT tables + metric_coverage are seeded.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
CREATE SCHEMA IF NOT EXISTS DERIVED;
USE SCHEMA DERIVED;
USE WAREHOUSE NBA_INGEST_WH;

-- Career steals leaders, era-scoped BY THE REGISTRY (not a hardcoded year).
-- Players whose entire career predates 1973-74 do NOT appear with a fabricated
-- 0 — they are correctly excluded, and every row carries `steals_tracked_from`
-- so the answer is self-documenting. This is what turns "store NULL correctly"
-- into "answer truthfully".
CREATE OR REPLACE VIEW vw_career_steals_leaders
COMMENT = 'Career steals leaders scoped to the (near-)complete era from FLAT.metric_coverage (1973-74+). Sporadic pre-1974 steals exist in the data (a ramp, not a cliff — Phase 3) but are excluded here for COMPARABILITY: partial-coverage seasons would make unfair career totals, not because the values are zero. Demonstrates coverage-aware aggregation; consumers ORDER BY career_steals DESC. Add analogous views (blocks/turnovers/3P) the same way.'
AS
WITH cov AS (
    SELECT first_tracked_season AS from_season
    FROM ZK_NBA_V2.FLAT.metric_coverage WHERE metric = 'stl'
)
SELECT
    b.player_id,
    ANY_VALUE(b.player_name)              AS player_name,
    SUM(b.stl)                            AS career_steals,
    COUNT(*)                              AS player_games_counted,
    MIN(b.season)                         AS first_season_counted,
    MAX(b.season)                         AS last_season_counted,
    (SELECT from_season FROM cov)         AS steals_tracked_from
FROM ZK_NBA_V2.FLAT.player_box_basic b
WHERE b.season >= (SELECT from_season FROM cov)   -- registry-driven era scope
  AND b.stl IS NOT NULL                           -- never coerce a not-tracked NULL to 0
GROUP BY b.player_id
ORDER BY career_steals DESC NULLS LAST;
