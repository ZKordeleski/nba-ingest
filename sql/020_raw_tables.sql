-- nba-ingest RAW tables.
-- One table per BR endpoint we scrape. VARIANT payload = exactly what BR returned
-- (parsed into a JSON-serializable structure, not the raw HTML).
-- Append-only: old rows are never deleted. Enables re-flattening without re-scraping.
--
-- Run after 001_bootstrap.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE SCHEMA RAW;
USE WAREHOUSE NBA_INGEST_WH;

-- --------------------------------------------------------------------------
-- raw_boxscores
-- One row per game page fetched from BR (/boxscores/YYYYMMDD0HOME.html).
-- The payload contains the parsed tables (basic, advanced, line_score,
-- four_factors) as JSON, not the full HTML.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ZK_NBA.RAW.raw_boxscores (
    game_slug     STRING     NOT NULL COMMENT 'BR game identifier, e.g. 20231025ODAL. Matches the URL path segment.',
    game_date     DATE       NOT NULL COMMENT 'Calendar date of the game (derived from slug).',
    home_team     STRING     NOT NULL COMMENT 'Home team BR abbreviation (last 3 chars of slug).',
    payload       VARIANT    NOT NULL COMMENT 'Parsed JSON: {basic: {...}, advanced: {...}, line_score: {...}, four_factors: {...}, meta: {...}}.',
    fetched_at    TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'Wall-clock time this row was written.'
)
COMMENT = 'Raw box score payloads from Basketball-Reference. Append-only. Use FLAT.player_box_basic for analysis.';

-- --------------------------------------------------------------------------
-- raw_schedule
-- One row per monthly schedule page fetched from BR.
-- /leagues/NBA_{year}_games-{month}.html
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ZK_NBA.RAW.raw_schedule (
    season_year   INT        NOT NULL COMMENT 'BR season end year (e.g. 2024 for the 2023-24 season).',
    month         STRING     NOT NULL COMMENT 'Lowercase month name (october, november, ..., june).',
    payload       VARIANT    NOT NULL COMMENT 'Parsed JSON array of game rows from the schedule table.',
    fetched_at    TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'Wall-clock time this row was written.'
)
COMMENT = 'Monthly schedule pages from Basketball-Reference. Used as an index to drive the backfill job.';

-- --------------------------------------------------------------------------
-- raw_draft
-- One row per annual draft class page fetched from BR.
-- /draft/NBA_{year}.html
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ZK_NBA.RAW.raw_draft (
    draft_year    INT        NOT NULL COMMENT 'The draft year (e.g. 2024).',
    payload       VARIANT    NOT NULL COMMENT 'Parsed JSON array of draft pick rows including career stats as of fetch time.',
    fetched_at    TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'Wall-clock time this row was written. Career stats snapshot at this timestamp.'
)
COMMENT = 'Annual draft class pages from Basketball-Reference. Career stats update on each fetch — this table is a historical log of snapshots.';
