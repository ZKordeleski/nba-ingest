-- Document the BAA series_slug linkage gap (2026-06-10) — best-practice handling of
-- a KNOWN, IMPLEMENTATION-pending data gap (not a source absence).
--
-- BAA playoff games (season<=1949) load with correct round/season_type, but their
-- series_slug is NULL: the defunct-team nicknames (PHW, CHS, ...) aren't mapped in
-- TEAM_NICKNAMES, so match_series can't link them. The brackets DO exist on BR — this
-- is our enrichment TODO, not missing source data. Recorded two ways so it's queryable,
-- not folklore: a metric_coverage registry row (the agent/audit consult this) and the
-- games.series_slug column comment (schema self-doc). Backlog: add BAA nicknames.
--
--   .venv/bin/python dev/apply_sql.py sql/v2/052_series_slug_coverage.sql

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

-- registry row. first_tracked_season=NULL because series_slug isn't an era-boundary
-- field (it's populated for any matched playoff game, NULL for regular season always);
-- the gap is era-scoped only for the unlinked BAA subset, captured in null_means.
DELETE FROM metric_coverage WHERE metric = 'series_slug';
INSERT INTO metric_coverage (metric, column_ref, first_tracked_season, status, null_means, authority) VALUES
    ('series_slug', 'games.series_slug', NULL, 'enrichment_pending',
     'NULL = regular-season game (N/A) OR a playoff game whose series is unlinked. Unlinked = ALL BAA playoff games (season<=1949): defunct-team nicknames unmapped in TEAM_NICKNAMES. This is OUR enrichment gap, NOT a source absence (BR has the BAA brackets). Disambiguate via season_type/round.',
     'BAA prefix + nickname gap, 2026-06-10 evidence; fix tracked in Deferred backlog');

COMMENT ON COLUMN games.series_slug IS
'BR playoff series this game belongs to. NULL for regular-season games (N/A); also NULL for a playoff game whose series could not be linked — currently ALL BAA playoff games (season<=1949), defunct-team nicknames unmapped (known enrichment gap, see metric_coverage + Deferred backlog; NOT a source absence). Disambiguate via season_type/round.';
