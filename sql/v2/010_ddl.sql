-- ZK_NBA_V2 — pure Basketball-Reference architecture. Phase 1 DDL.
--
-- Single source: every row comes from Basketball-Reference. There is NO `source`
-- column anywhere — one source means one semantic. game_id is always the BR slug
-- (YYYYMMDD0TTT). No NBA-numeric IDs, no cross-source joins, no impersonation.
--
-- See REBUILD_METHOD.md for the design decisions encoded here:
--   - round/series is first-class (closes the V1 FINALS gap)
--   - metric_coverage is the source of truth for stat-availability per era
--     (a NULL is never an ambiguous zero — see the no-ambiguous-NULL invariant)
--   - decimal minutes, is_starter, arena from scorebox_meta
--
-- Run: .venv/bin/python dev/apply_sql.py sql/v2/010_ddl.sql

USE ROLE DEVELOPER_ADMIN;
CREATE DATABASE IF NOT EXISTS ZK_NBA_V2;
USE DATABASE ZK_NBA_V2;
CREATE SCHEMA IF NOT EXISTS FLAT;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

-- ==========================================================================
-- playoff_series — authoritative playoff structure, one row per series.
-- Source: BR bracket page /playoffs/NBA_{year}.html (round-encoded series slugs).
-- This is what makes "the Finals" a first-class, queryable thing.
-- ==========================================================================
CREATE OR REPLACE TABLE playoff_series (
    series_slug    STRING  NOT NULL COMMENT 'BR series-page slug, e.g. 2023-nba-finals-heat-vs-nuggets. Stable natural key.',
    season         INT     NOT NULL COMMENT 'NBA season end-year (2025 = 2024-25 season).',
    round          STRING           COMMENT 'Canonical round: First Round | Conference Semifinals | Conference Finals | Finals | Play-In. Parsed from the series slug / bracket headings.',
    round_seq      INT              COMMENT 'Round ordering within a postseason: 1=First Round … 4=Finals (Play-In=0). For sorting.',
    conference     STRING           COMMENT 'Eastern | Western | NULL for the Finals (cross-conference).',
    team_a_abbr    STRING           COMMENT 'BR abbr of one participant (higher seed by BR ordering).',
    team_b_abbr    STRING           COMMENT 'BR abbr of the other participant.',
    winner_abbr    STRING           COMMENT 'BR abbr of the series winner. NULL if unresolved.',
    games_played   INT              COMMENT 'Number of games in the series.',
    fetched_at     TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (series_slug)
)
COMMENT = 'One row per playoff series, from the BR bracket page. Join games.series_slug -> playoff_series.series_slug to label any postseason game with its round. The Finals is round = ''Finals''.';

-- ==========================================================================
-- games — one row per game, both teams wide. game_id = BR slug.
-- V2 deltas vs V1: no `source`; season_type properly sourced; round/series_slug/
-- game_in_series first-class; arena_name/city/state from scorebox_meta.
-- ==========================================================================
CREATE OR REPLACE TABLE games (
    game_id          STRING  NOT NULL COMMENT 'BR game slug (YYYYMMDD0TTT, e.g. 202306120DEN). The only game identifier in V2.',
    game_date        DATE    NOT NULL COMMENT 'Calendar date the game was played (from the slug / scorebox).',
    season           INT              COMMENT 'NBA season end-year (Oct-Jun spans: a Nov 2024 game is season 2025).',
    season_type      STRING           COMMENT 'Regular Season | Playoffs | Play-In | Preseason | NBA Cup. Sourced from playoff_series membership + schedule context, NOT derived from game_id (the V1 LEFT(game_id,1) anti-pattern).',
    round            STRING           COMMENT 'Playoff round for postseason games (First Round | Conference Semifinals | Conference Finals | Finals | Play-In); NULL for regular season. Denormalized from playoff_series for query convenience.',
    series_slug      STRING           COMMENT 'FK -> playoff_series.series_slug for postseason games; NULL otherwise.',
    game_in_series   INT              COMMENT 'Game number within the playoff series (1..7), parsed from the boxscore <h1> ("… Game 5"). NULL for regular season.',
    home_team_abbr   STRING           COMMENT 'Home team BR abbreviation (DEN, BRK, CHO, PHO). BR abbr is the canonical team identifier in V2 — single-source. An NBA-Stats team_id bridge is a later slice (only needed for cross-dataset joins). See Deferred backlog.',
    away_team_abbr   STRING           COMMENT 'Away team BR abbreviation.',
    home_pts         INT              COMMENT 'Home final score.',
    away_pts         INT              COMMENT 'Away final score.',
    home_wl          STRING           COMMENT 'W or L from the home perspective.',
    arena_name       STRING           COMMENT 'Venue, from scorebox_meta segment 2 (e.g. Ball Arena). NULL pre-1955 (no meta block on early BAA games).',
    arena_city       STRING           COMMENT 'Venue city from scorebox_meta.',
    arena_state      STRING           COMMENT 'Venue state/region from scorebox_meta.',
    -- team box aggregates (home)
    home_fgm INT, home_fga INT, home_fg_pct FLOAT, home_fg3m INT, home_fg3a INT, home_fg3_pct FLOAT,
    home_ftm INT, home_fta INT, home_ft_pct FLOAT, home_oreb INT, home_dreb INT, home_reb INT,
    home_ast INT, home_stl INT, home_blk INT, home_tov INT, home_pf INT, home_plus_minus INT,
    -- team box aggregates (away)
    away_fgm INT, away_fga INT, away_fg_pct FLOAT, away_fg3m INT, away_fg3a INT, away_fg3_pct FLOAT,
    away_ftm INT, away_fta INT, away_ft_pct FLOAT, away_oreb INT, away_dreb INT, away_reb INT,
    away_ast INT, away_stl INT, away_blk INT, away_tov INT, away_pf INT, away_plus_minus INT,
    fetched_at       TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (game_id)
)
COMMENT = 'One row per game, both teams wide. Single-source (BR). season_type/round are sourced from the playoff bracket + schedule, never from the game_id. Stat columns follow metric_coverage: pre-tracking-era stats are NULL (not 0) — see metric_coverage.';

-- ==========================================================================
-- player_box_basic — one row per player per game.
-- V2 deltas: no `source`; minutes_played FLOAT (decimal, not rounded INT);
-- is_starter BOOLEAN (from row position vs the Reserves separator).
-- ==========================================================================
CREATE OR REPLACE TABLE player_box_basic (
    game_id          STRING  NOT NULL COMMENT 'Join to games.game_id (BR slug).',
    player_id        STRING  NOT NULL COMMENT 'BR player slug (e.g. jokicni01) — the canonical player identifier in V2 (single-source). An NBA-Stats player_id bridge is a later slice; see Deferred backlog.',
    player_name      STRING           COMMENT 'Full name as shown on BR (may carry diacritics: Jokić).',
    team_abbr        STRING           COMMENT 'Player''s team BR abbreviation this game.',
    is_home          BOOLEAN          COMMENT 'True if the player''s team was home.',
    is_starter       BOOLEAN          COMMENT 'True if the player appeared above the "Reserves" separator in the BR basic box (i.e., a starter).',
    is_win           BOOLEAN          COMMENT 'True if the player''s team won.',
    season           INT              COMMENT 'NBA season end-year.',
    season_type      STRING           COMMENT 'Denormalized from games.season_type for this game.',
    minutes_played   FLOAT            COMMENT 'Decimal minutes (36:08 -> 36.13). NULL for DNP. (V1 stored a rounded INT; V2 preserves the seconds.)',
    pts INT, ast INT, reb INT, oreb INT, dreb INT, stl INT, blk INT, tov INT, pf INT,
    fgm INT, fga INT, fg_pct FLOAT, fg3m INT, fg3a INT, fg3_pct FLOAT, ftm INT, fta INT, ft_pct FLOAT,
    plus_minus FLOAT COMMENT 'Plus/minus for the game. NULL where BR omits it.',
    game_score FLOAT COMMENT 'BR Game Score (GmSc), a single-number performance metric. Present from ~1978-79.',
    fetched_at       TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (game_id, player_id)
)
COMMENT = 'One row per player per game, basic box. Single-source (BR). Counting stats follow metric_coverage: stl/blk/oreb/dreb are NULL before 1973-74, tov before 1977-78, fg3* before 1979-80 — a NULL there means NOT RECORDED, never 0. minutes_played is decimal.';

-- ==========================================================================
-- player_box_advanced — one row per player per game (advanced metrics).
-- ==========================================================================
CREATE OR REPLACE TABLE player_box_advanced (
    game_id        STRING  NOT NULL COMMENT 'Join to player_box_basic on (game_id, player_id).',
    player_id      STRING  NOT NULL COMMENT 'BR player slug; matches player_box_basic.player_id.',
    ts_pct FLOAT, efg_pct FLOAT, fg3a_rate FLOAT, fta_rate FLOAT,
    orb_pct FLOAT, drb_pct FLOAT, trb_pct FLOAT, ast_pct FLOAT,
    stl_pct FLOAT, blk_pct FLOAT, tov_pct FLOAT, usg_pct FLOAT,
    ortg INT, drtg INT, bpm FLOAT,
    fetched_at     TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (game_id, player_id)
)
COMMENT = 'Advanced box per player per game. BR publishes the advanced table from >=1985 (verified Phase 0); derivable metrics (ts/efg) follow their input availability per metric_coverage. Metrics requiring stats not yet tracked in an era are NULL there.';

-- ==========================================================================
-- line_scores — quarter-by-quarter, one row per game (home+away wide).
-- ==========================================================================
CREATE OR REPLACE TABLE line_scores (
    game_id        STRING  NOT NULL COMMENT 'Join to games.game_id.',
    game_date      DATE,
    home_team_abbr STRING, home_q1 INT, home_q2 INT, home_q3 INT, home_q4 INT,
    home_ot1 INT, home_ot2 INT, home_ot3 INT, home_ot4 INT, home_pts INT,
    away_team_abbr STRING, away_q1 INT, away_q2 INT, away_q3 INT, away_q4 INT,
    away_ot1 INT, away_ot2 INT, away_ot3 INT, away_ot4 INT, away_pts INT,
    fetched_at     TIMESTAMP_NTZ,

    PRIMARY KEY (game_id)
)
COMMENT = 'Quarter-by-quarter scoring, one row per game. Source: BR line_score (comment-hidden table). OT columns NULL when the game had fewer overtimes.';

-- NOTE: `player_quarter_box` is deferred to Phase 2 (full-season extraction) — it
-- comes free from the same boxscore pages Phase 2 re-scrapes, and wasn't in the
-- plan's original Phase 1 scope. Its era coverage is already recorded in
-- metric_coverage so the registry is complete ahead of the table.
--
-- NOTE: `players` (bio) and `teams` (incl. the NBA-Stats id bridge) are NOT
-- created in Phase 1 — per principle #6 (no empty WIP tables), a table exists
-- only once it has a loader. They need player-page / team-page fetches that
-- aren't part of this slice. Tracked in the Deferred backlog; added in Phase 2.

-- ==========================================================================
-- metric_coverage — THE source of truth for stat-availability per era.
-- Authored from NBA tracking-start seasons (domain ground truth), verified
-- against cell population. NEVER auto-derived from the scrape (Phase 0 finding:
-- BR's column template is uniform across eras, so column presence lies).
-- The agent / guardrail views consult this to interpret any NULL.
-- ==========================================================================
CREATE OR REPLACE TABLE metric_coverage (
    metric               STRING  NOT NULL COMMENT 'Logical metric, e.g. stl, blk, tov, fg3m, player_quarter_box.',
    column_ref           STRING           COMMENT 'The physical column(s) this governs, e.g. player_box_basic.stl.',
    first_tracked_season INT              COMMENT 'NBA season end-year the stat was first recorded (1974 = 1973-74). NULL = always available.',
    status               STRING  NOT NULL COMMENT 'tracked_from | derivable | always | br_published_from.',
    null_means           STRING           COMMENT 'How to interpret a NULL BEFORE first_tracked_season: "not recorded (not zero)".',
    authority            STRING           COMMENT 'NBA official rule change | BR publication boundary (Phase 0 verified).',

    PRIMARY KEY (metric)
)
COMMENT = 'Stat-availability registry. A NULL in a fact table resolves here to either not-tracked-this-era (interpret as N/A, never 0) or tracked-but-missing-this-game. The single mechanism that prevents the "Bill Russell had 0 steals" / "no Finals before 2024" class of confidently-wrong answer.';
