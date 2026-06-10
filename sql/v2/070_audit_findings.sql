-- ZK_NBA_V2 audit_findings — the "pending judgment" ledger (Zack's call).
--
-- The third disposition toward a game, alongside quarantine (excluded) and
-- data_caveats (included-but-flagged): a finding the SYSTEM surfaced that WE
-- have not yet ruled on. Today the audit's FLAGS print to stdout and evaporate;
-- this gives "the system finds; we judge" a durable, queryable inbox.
--
-- Findings are written from two places, same disposition, same table:
--   * load-time   — slice.build_game emits e.g. an 'orientation' finding when a
--                   game's home/away is ambiguous (slug-home absent from box tables).
--   * audit-time  — dev/_audit.py writes 'completeness', 'caveat_rate', etc.
--
-- A finding, once adjudicated, is PROMOTED by a row move: ruled bad -> quarantine,
-- ruled real-imperfection -> data_caveats, ruled benign -> status='benign'.
--
-- Shares the column vocabulary of the ledger family: subject, type, detail,
-- magnitude, first/last_seen, status.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

CREATE TABLE IF NOT EXISTS audit_findings (
    finding_key   STRING  NOT NULL COMMENT 'Stable dedupe key (detector || ":" || subject_id) so re-runs MERGE, not duplicate.',
    detector      STRING  NOT NULL COMMENT 'Which check raised it: completeness | caveat_rate | orientation | range_team_pts | quarantine_rate | ...',
    scope         STRING  NOT NULL COMMENT 'Grain of the subject: season | game | column | player.',
    subject_id    STRING           COMMENT 'The season / game_id / column / player_id the finding is about.',
    severity      STRING           COMMENT 'info | warn | error.',
    detail        STRING           COMMENT 'Human-readable explanation, enough to adjudicate.',
    metric_value  FLOAT            COMMENT 'The measured number (residual count, caveat fraction, |diff|). NULL if N/A.',
    first_seen_at TIMESTAMP_NTZ    COMMENT 'When the finding first appeared.',
    last_seen_at  TIMESTAMP_NTZ    COMMENT 'When it was last observed (bumped each run it recurs).',
    status        STRING DEFAULT 'open' COMMENT 'open | benign | bug | promoted_caveat | promoted_quarantine | resolved.',
    note          STRING           COMMENT 'Adjudication note (why we ruled the way we did).'
)
COMMENT = 'Pending-judgment ledger: anomalies the system surfaced, awaiting our ruling. One row per (detector, subject). Promotion to quarantine/caveat is a row move. The durable inbox for "the system finds; we judge".';

USE SCHEMA DERIVED;
CREATE OR REPLACE VIEW vw_open_findings
COMMENT = 'Open (un-adjudicated) audit findings, newest first — the worklist.'
AS
SELECT detector, scope, subject_id, severity, metric_value, detail, first_seen_at, last_seen_at
FROM ZK_NBA_V2.FLAT.audit_findings
WHERE status = 'open'
ORDER BY severity DESC, last_seen_at DESC;
