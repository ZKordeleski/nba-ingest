-- ZK_NBA_V2 quarantine — game-grain worklist (Zack's call: "more detailed than season").
--
-- Disposition: EXCLUDED. Games we attempted and rejected (bad/impossible data, a
-- missing required table, a fetch error). NOT a graveyard — a worklist that DRAINS:
-- loaders MERGE on game_id and DELETE the row when a game later loads successfully,
-- so a falling open count is a real signal of parser progress.
--
-- Game-grain, because the slug is a deterministic id: YYYYMMDD0TTT yields game_date,
-- home_team_abbr (RIGHT 3), and season EVEN ON TOTAL FAILURE — a quarantine row is
-- never empty (no-ambiguous-NULL at the failure boundary too). Typed axes we always
-- slice on; a VARIANT `context` for stage-specific diagnostics (a field graduates to
-- a real column when a query earns it).
--
-- ⚠️ APPLY AT THE POST-BACKFILL GATE — never while a load is mid-INSERT. This
-- migration drops the ad-hoc 3-column quarantine; a concurrent loader would fail.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

CREATE TABLE IF NOT EXISTS quarantine_rich (
    game_id        STRING NOT NULL COMMENT 'BR slug; the canonical id even though it never reached `games`.',
    season         INT             COMMENT 'NBA season end-year (from slug date): Nov 1972 -> 1973.',
    game_date      DATE            COMMENT 'From slug YYYYMMDD; a quarantine row is never undated.',
    home_team_abbr STRING          COMMENT 'slug RIGHT(3); known for free.',
    away_team_abbr STRING          COMMENT 'NULL if we could not parse the opponent.',
    reason_class   STRING NOT NULL COMMENT 'fetch_error | missing_table | no_team_totals | guard_blocker.',
    failure_stage  STRING          COMMENT 'fetch | parse | flatten | guard — WHERE to go fix it.',
    detail         STRING          COMMENT 'Human-readable reason.',
    context        VARIANT         COMMENT 'Stage-specific diagnostics: {missing_tables:[], blockers:[], http_status, ...}.',
    first_seen_at  TIMESTAMP_NTZ,
    last_seen_at   TIMESTAMP_NTZ,
    attempts       INT             COMMENT 'How many times we have tried and rejected this game.',
    status         STRING DEFAULT 'open' COMMENT 'open | resolved | wontfix.',
    resolution_note STRING
)
COMMENT = 'Games attempted and rejected — a worklist, not a graveyard. Game-grain; slug gives date/home/season for free. MERGE on game_id; loaders DELETE on later success so it DRAINS.';

-- One-time migration of the legacy ad-hoc table (game_id, reason, fetched_at).
-- Derives the slug-encoded fields and classifies the free-text reason. Guarded so
-- re-running is a no-op once quarantine_rich is populated.
INSERT INTO quarantine_rich
  (game_id, season, game_date, home_team_abbr, reason_class, failure_stage,
   detail, first_seen_at, last_seen_at, attempts, status)
SELECT
    q.game_id,
    TRY_TO_NUMBER(SUBSTR(q.game_id, 1, 4))
      + IFF(TRY_TO_NUMBER(SUBSTR(q.game_id, 5, 2)) >= 10, 1, 0)            AS season,
    TRY_TO_DATE(SUBSTR(q.game_id, 1, 8), 'YYYYMMDD')                       AS game_date,
    RIGHT(q.game_id, 3)                                                    AS home_team_abbr,
    CASE
        WHEN q.reason ILIKE 'error:%'                THEN 'fetch_error'
        WHEN q.reason ILIKE '%missing required table%' THEN 'missing_table'
        WHEN q.reason ILIKE '%no team totals%'       THEN 'no_team_totals'
        ELSE 'guard_blocker'
    END                                                                   AS reason_class,
    CASE
        WHEN q.reason ILIKE 'error:%'                THEN 'fetch'
        WHEN q.reason ILIKE '%missing required table%' THEN 'parse'
        WHEN q.reason ILIKE '%no team totals%'       THEN 'flatten'
        ELSE 'guard'
    END                                                                   AS failure_stage,
    q.reason, q.fetched_at, q.fetched_at, 1, 'open'
FROM quarantine q
WHERE NOT EXISTS (SELECT 1 FROM quarantine_rich);

DROP TABLE IF EXISTS quarantine;
ALTER TABLE quarantine_rich RENAME TO quarantine;

USE SCHEMA DERIVED;
CREATE OR REPLACE VIEW vw_quarantine_rate
COMMENT = 'Open quarantines per season x reason x stage — the completeness ally. A rate spike is a systematic parse bug masquerading as "that era was just bad data".'
AS
SELECT season, reason_class, failure_stage, COUNT(*) AS n,
       MIN(first_seen_at) AS since, MAX(last_seen_at) AS last_seen
FROM ZK_NBA_V2.FLAT.quarantine
WHERE status = 'open'
GROUP BY 1, 2, 3
ORDER BY season, n DESC;
