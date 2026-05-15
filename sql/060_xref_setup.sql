-- DERIVED.player_xref + DERIVED.official_xref — ID resolution tables.
--
-- Maps BR slugs to canonical NBA Stats API IDs. Populated in two phases:
--   1. From JB seed: SELECT DISTINCT (player_id, player_name) — gives ~6,533
--      entries with NULL br_slug (we don't know BR's slug for these players
--      yet; the name is the lookup key).
--   2. From BR scrape at runtime: when a new br_slug is encountered, the
--      resolver in Python:
--         a) Looks up by br_slug. If hit, use the cached nba_id.
--         b) Looks up by player_name. If hit, UPDATE br_slug for this row
--            so future lookups are O(1) by slug.
--         c) Cache miss + name miss: fetch BR player page, extract nba_id
--            from the stats.nba.com external link, INSERT a new row.
--
-- The canonical FLAT tables (player_box_basic, player_box_advanced,
-- game_officials, game_inactives) write the resolved nba_id as player_id /
-- official_id. The br_slug remains in br_player_slug / br_official_slug for
-- diagnostic traceability.
--
-- Run after 040_flat_tables.sql and (for the JB seed entries) after seeding
-- 050_seed_from_jb has populated player_box_basic + game_officials.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE SCHEMA DERIVED;
USE WAREHOUSE NBA_INGEST_WH;

-- --------------------------------------------------------------------------
-- player_xref
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.DERIVED.player_xref (
    nba_id        STRING  NOT NULL COMMENT 'Canonical NBA Stats API player ID. PK.',
    br_slug       STRING           COMMENT 'BR player slug (e.g., wembavi01). NULL for JB-seed-derived rows until a BR scrape backfills via name match. Once set, stable.',
    player_name   STRING           COMMENT 'Best known display name. From JB seed: ASCII. From BR resolve: may include diacritics. Used for fallback name match.',
    source        STRING           COMMENT 'jb_seed | br_resolve. Which path populated this row originally.',
    fetched_at    TIMESTAMP_NTZ    COMMENT 'Time the row was inserted/last updated.',

    PRIMARY KEY (nba_id)
)
COMMENT = 'Resolver cache mapping BR player slugs to canonical NBA Stats API IDs. Seeded from JB; extended at runtime by br_resolve fetches. Lookup order: by br_slug, then by player_name, then fetch.';

-- Seed from JB player_box_basic — distinct (nba_id, name) pairs
INSERT INTO ZK_NBA.DERIVED.player_xref (nba_id, br_slug, player_name, source, fetched_at)
SELECT DISTINCT
    player_id          AS nba_id,
    NULL               AS br_slug,
    player_name        AS player_name,
    'jb_seed'          AS source,
    CURRENT_TIMESTAMP() AS fetched_at
FROM ZK_NBA.FLAT.player_box_basic
WHERE source = 'jb_seed'
QUALIFY ROW_NUMBER() OVER (PARTITION BY player_id ORDER BY player_name DESC NULLS LAST) = 1;
-- Expected: ~6,533 rows (one per JB-seeded player)

-- --------------------------------------------------------------------------
-- official_xref
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.DERIVED.official_xref (
    nba_id        STRING  NOT NULL COMMENT 'Canonical NBA Stats API official ID (stringified). PK.',
    br_slug       STRING           COMMENT 'BR referee slug (e.g., davisma99r). NULL for JB-derived rows.',
    first_name    STRING           COMMENT 'Official''s first name.',
    last_name     STRING           COMMENT 'Official''s last name.',
    source        STRING           COMMENT 'jb_seed | br_resolve.',
    fetched_at    TIMESTAMP_NTZ    COMMENT 'Time the row was inserted/last updated.',

    PRIMARY KEY (nba_id)
)
COMMENT = 'Resolver cache mapping BR referee slugs to canonical NBA Stats API official IDs. Seeded from JB; extended at runtime.';

-- Seed from JB game_officials — distinct (nba_id, first, last) sets
INSERT INTO ZK_NBA.DERIVED.official_xref (nba_id, br_slug, first_name, last_name, source, fetched_at)
SELECT DISTINCT
    official_id        AS nba_id,
    NULL               AS br_slug,
    first_name         AS first_name,
    last_name          AS last_name,
    'jb_seed'          AS source,
    CURRENT_TIMESTAMP() AS fetched_at
FROM ZK_NBA.FLAT.game_officials
WHERE official_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY official_id ORDER BY last_name DESC NULLS LAST) = 1;
-- Expected: ~235 rows (one per JB-seeded official)

-- Verify
SELECT 'player_xref' AS tbl, COUNT(*) AS n, COUNT(br_slug) AS with_slug FROM ZK_NBA.DERIVED.player_xref;
SELECT 'official_xref' AS tbl, COUNT(*) AS n, COUNT(br_slug) AS with_slug FROM ZK_NBA.DERIVED.official_xref;
