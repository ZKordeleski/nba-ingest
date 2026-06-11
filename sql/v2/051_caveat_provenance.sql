-- Add approval provenance to data_caveats (M3, 2026-06-10, Zack's call).
--
-- A caveat exists ONLY because a human reviewed a quarantined game and admitted it
-- (dev/_approve.py). These columns make the imperfection and its accountability one
-- row — and let the modeler agent SEE, at query time, that a game was approved
-- despite a flag, by whom, and why. The "interesting findings" surface the agent
-- wants is then just a view over this table, never a separate (drift-prone) copy.
--
-- Columns are nullable (the table predates this; legacy rows are re-quarantined at
-- the gate and re-approved WITH provenance). Non-null is enforced at the app layer:
-- dev/_approve.py requires --reviewer and --note.
--
-- Idempotent. Apply now (additive, safe):
--   .venv/bin/python dev/apply_sql.py sql/v2/051_caveat_provenance.sql

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

ALTER TABLE data_caveats ADD COLUMN IF NOT EXISTS reviewed_by  STRING
    COMMENT 'Who approved admitting this flagged game (dev/_approve.py --reviewer).';
ALTER TABLE data_caveats ADD COLUMN IF NOT EXISTS reviewed_at  TIMESTAMP_NTZ
    COMMENT 'When the human approved it.';
ALTER TABLE data_caveats ADD COLUMN IF NOT EXISTS review_note  STRING
    COMMENT 'Why it was admitted despite the flag (the reviewer''s rationale).';

USE SCHEMA DERIVED;
CREATE OR REPLACE VIEW vw_data_caveats
COMMENT = 'Approved data caveats + provenance, joined to game context — the agent/analyst surface for "what is imperfect, why, and who approved it". The single source; build any "interesting findings" slice as another view over data_caveats, never a copy.'
AS
SELECT c.caveat_type, c.magnitude, c.detail, c.game_id, c.player_id,
       g.season, g.game_date, g.season_type, g.round,
       g.away_team_abbr || ' @ ' || g.home_team_abbr AS matchup,
       g.away_pts || '-' || g.home_pts AS score,
       c.reviewed_by, c.reviewed_at, c.review_note
FROM ZK_NBA_V2.FLAT.data_caveats c
LEFT JOIN ZK_NBA_V2.FLAT.games g USING (game_id);
