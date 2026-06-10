-- ZK_NBA_V2 data caveats — the "admit-with-a-flag" surface (Zack's call).
--
-- Some games are real but carry a known imperfection we consciously admit rather
-- than hide: e.g. BR reconciles team totals from official league records against
-- separately-sourced, incomplete historical player box scores, so old player sums
-- fall a few points short of the known team total (documented provenance, not our
-- bug). Rather than silently tolerate (which would blunt the guard) or exclude
-- (which loses real games), we LOAD the game and record a typed caveat here.
--
-- This is the single, extensible surface for EVERY "weird caveat born from
-- scraping" — reconciliation discrepancies today, id-collisions (two same-named
-- players sharing a slug), etc. Egregious/bug-sized problems still quarantine.

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
