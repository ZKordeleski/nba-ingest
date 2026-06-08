-- ZK_NBA_V2 Phase 2 DDL — per-game meta tables (officials, inactives).
-- Single-source: official_id / player_id are BR slugs (no NBA-Stats id). From
-- the boxscore meta block (fetchers/boxscore._parse_meta). Officials are anchored
-- (linked to /referees/{slug}) from 1995+ (Phase 0); pre-1995 they're bare names
-- with no slug — recorded then in metric_coverage terms as name-only.
--
-- Run after 010_ddl.sql: .venv/bin/python dev/apply_sql.py sql/v2/030_phase2_ddl.sql

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

CREATE TABLE IF NOT EXISTS game_officials (
    game_id       STRING  NOT NULL COMMENT 'Join to games.game_id.',
    official_id   STRING  NOT NULL COMMENT 'BR referee slug (e.g. davisma99r) — canonical official id in V2. NULL-slug eras (pre-1995) fall back to the name.',
    official_name STRING           COMMENT 'Referee full name as shown on BR.',
    fetched_at    TIMESTAMP_NTZ,

    PRIMARY KEY (game_id, official_id)
)
COMMENT = 'Referee assignments per game, from the BR boxscore meta block. Anchored slugs from 1995+ (Phase 0); bare names before. NBA Finals games carry 4 officials, not 3 — do not assert a count of 3.';

CREATE TABLE IF NOT EXISTS game_inactives (
    game_id     STRING  NOT NULL COMMENT 'Join to games.game_id.',
    player_id   STRING  NOT NULL COMMENT 'BR player slug; matches player_box_basic.player_id when the player later plays.',
    player_name STRING           COMMENT 'Player full name from the meta block.',
    team_abbr   STRING           COMMENT 'BR abbr of the team the inactive player was rostered on.',
    fetched_at  TIMESTAMP_NTZ,

    PRIMARY KEY (game_id, player_id)
)
COMMENT = 'Players listed inactive for a game, from the BR meta block. Present in the modern era (Phase 0: matched from ~2010 on the sampled pages). inactive_reason (injury/rest/G-League) is in the Deferred backlog.';
