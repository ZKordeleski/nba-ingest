-- ZK_NBA_V2 data caveats — "a human approved this game knowing this imperfection".
--
-- IMPORTANT (2026-06-10, strict guardrail): a caveat is NOT an ingest disposition.
-- Ingest is binary — clean -> admit; ANY flag -> quarantine (never admit-on-caveat).
-- A row appears here ONLY when a human reviews a quarantined game and approves it
-- back via dev/_approve.py, which re-admits the game AND records its flagged issues
-- as the typed caveats below. So every caveat means a human consciously accepted a
-- known imperfection (e.g. BR's team total vs incomplete historical player rows; a
-- same-name player_id collision) — never a guardrail the machine silently waved
-- through. Bug-sized problems a reviewer rejects simply stay quarantined.
--
-- Extensible surface for EVERY approved "weird thing born from scraping":
-- reconciliation_discrepancy, line_score_discrepancy, player_id_collision, ...

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

CREATE TABLE IF NOT EXISTS data_caveats (
    game_id      STRING  NOT NULL COMMENT 'Join to games.game_id.',
    player_id    STRING           COMMENT 'BR player slug if the caveat is player-scoped (e.g. id collision); NULL if game-scoped.',
    caveat_type  STRING  NOT NULL COMMENT 'reconciliation_discrepancy | player_id_collision | ... (extensible).',
    detail       STRING           COMMENT 'Human-readable explanation, incl. which side disagrees.',
    magnitude    INT              COMMENT 'Size of the discrepancy in the caveat''s natural unit (e.g. |player_pts_sum - team_total|). NULL if N/A.',
    fetched_at   TIMESTAMP_NTZ
)
COMMENT = 'Known, consciously-admitted data imperfections — one row per (game, caveat). The game IS loaded; this records why it is imperfect so consumers can annotate/exclude and future cleanup is easy. Bug-sized problems are quarantined, not caveated.';

USE SCHEMA DERIVED;
CREATE OR REPLACE VIEW vw_data_caveats
COMMENT = 'Data caveats joined to game context (date, teams) — the agent/analyst-facing surface for "what is imperfect and why". Filter or annotate on this; e.g. exclude reconciliation_discrepancy games from exact-points leaderboards.'
AS
SELECT c.caveat_type, c.magnitude, c.detail, c.game_id, c.player_id,
       g.season, g.game_date, g.season_type, g.round,
       g.away_team_abbr || ' @ ' || g.home_team_abbr AS matchup,
       g.away_pts || '-' || g.home_pts AS score
FROM ZK_NBA_V2.FLAT.data_caveats c
LEFT JOIN ZK_NBA_V2.FLAT.games g USING (game_id);
-- Root cause of caveat_type='reconciliation_discrepancy' is documented (with
-- sources) in docs/BR_DATA_CATALOG.md → "Source reconciliation discrepancies".
