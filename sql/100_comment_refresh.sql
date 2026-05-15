-- Refresh Snowflake column comments to reflect post-fix reality.
--
-- Run this once after the team-id fix + BR-canonical swap (2026-05-15).
-- It ALTERs column comments without touching data — safe to re-run.
--
-- The 040_flat_tables.sql DDL is also updated with these same comments so
-- future bootstraps get them automatically. This file fixes the LIVE DB.

USE ROLE DEVELOPER_ADMIN;
USE WAREHOUSE NBA_INGEST_WH;
USE DATABASE ZK_NBA;

-- --------------------------------------------------------------------------
-- games
-- --------------------------------------------------------------------------
ALTER TABLE FLAT.games ALTER COLUMN season_id COMMENT
$$NBA season-type-prefixed season code. JB seed: from JB GAME.SEASON_ID directly (e.g. 22022 = 2022-23 regular season, 42022 = playoffs). BR scrape: derived as <first digit of game_id> || LPAD(season - 1, 4, '0') — same format.$$;

ALTER TABLE FLAT.games ALTER COLUMN home_plus_minus COMMENT
$$Home team plus/minus. JB seed: from JB GAME.PLUS_MINUS_HOME (NBA-Stats-API authoritative value, may be 0 for legacy games). BR scrape: derived as home_pts - away_pts (correct for regulation; coarser than the API value for OT games but always within rounding).$$;

ALTER TABLE FLAT.games ALTER COLUMN away_plus_minus COMMENT
$$Away team plus/minus. JB: NBA Stats API value. BR: derived as away_pts - home_pts. Same caveats as home_plus_minus.$$;

ALTER TABLE FLAT.games ALTER COLUMN home_team_id COMMENT
$$NBA Stats API team ID for the home team. JB seed: from JB GAME.TEAM_ID_HOME directly. BR scrape: resolved from home_team_abbr via FLAT.teams.abbreviation lookup, with BR->NBA translation (BRK->BKN, CHO->CHA, PHO->PHX) applied first.$$;

ALTER TABLE FLAT.games ALTER COLUMN away_team_id COMMENT
$$NBA Stats API team ID for the away team. Same resolution path as home_team_id.$$;

-- --------------------------------------------------------------------------
-- player_box_basic
-- --------------------------------------------------------------------------
ALTER TABLE FLAT.player_box_basic ALTER COLUMN team_id COMMENT
$$NBA Stats API team ID for the player's team this game. JB seed: resolved at seed time via JOIN to FLAT.team_history on (city || ' ' || nickname) with date-range filter on year_founded/year_active_till — handles historical franchise renames/relocations. BR scrape: resolved via daily_settle's _resolve_team_ids_for_game from team_abbr with BR->NBA translation (BRK->BKN, CHO->CHA, PHO->PHX). ~1.65% NULL on pre-1965 BAA-era and defunct-franchise rows (Syracuse Nationals, Rochester Royals, etc.) where team_history doesn't extend.$$;

ALTER TABLE FLAT.player_box_basic ALTER COLUMN team_abbr COMMENT
$$Player's team abbreviation. JB seed: NBA Stats API style (e.g. DEN, BKN, CHA, PHX) — looked up from team_history-resolved team_id. BR scrape: BR style (e.g. DEN, BRK, CHO, PHO) — stored as scraped. Use team_id for cross-source joins; team_abbr is display-only and source-flavored.$$;

ALTER TABLE FLAT.player_box_basic ALTER COLUMN team_name COMMENT
$$Player's team full name (city + nickname). JB seed: from JB PLAYERTEAMCITY || ' ' || PLAYERTEAMNAME — may include historical names (e.g. 'Vancouver Grizzlies', 'Seattle SuperSonics'). BR scrape: looked up from FLAT.teams.full_name after team_abbr resolution — always the current franchise name.$$;

ALTER TABLE FLAT.player_box_basic ALTER COLUMN opponent_team_name COMMENT
$$Opposing team full name. JB seed: from OPPONENTTEAMCITY || ' ' || OPPONENTTEAMNAME (historical names possible). BR scrape: derived post-MERGE by joining games on game_id and picking the OTHER team's full_name.$$;

ALTER TABLE FLAT.player_box_basic ALTER COLUMN season COMMENT
$$NBA season end year (e.g. 2023 = 2022-23 season). Derived from game_date: MONTH(game_date) >= 10 ? YEAR + 1 : YEAR. Covers the Oct-Jun NBA calendar; pre-Oct games are end-of-prior-season.$$;

ALTER TABLE FLAT.player_box_basic ALTER COLUMN game_type COMMENT
$$One of: 'Regular Season', 'Playoffs', 'Play-in Tournament', 'NBA Cup', 'NBA Emirates Cup', 'Preseason'. JB seed: from JB GAMETYPE column directly. BR scrape: derived from first digit of game_id (2=Regular Season, 4=Playoffs, 5=Play-in, 6=NBA Cup, 0/1=Preseason).$$;

ALTER TABLE FLAT.player_box_basic ALTER COLUMN minutes_played COMMENT
$$Minutes played as INT (rounded down from NBA's MM:SS internal format). DNP entries: NULL or 0. Sum over a team for a regulation game is typically 235-240 (rounding loss across 5 players) rather than exactly 240; OT games proportionally higher.$$;

-- --------------------------------------------------------------------------
-- game_inactives
-- --------------------------------------------------------------------------
ALTER TABLE FLAT.game_inactives ALTER COLUMN team_id COMMENT
$$NBA Stats API team ID the player was rostered on for this game. JB seed: from JB INACTIVE_PLAYERS.TEAM_ID directly. BR scrape: resolved post-MERGE from team_abbr via FLAT.teams lookup with BR->NBA translation.$$;

-- --------------------------------------------------------------------------
-- Table-level comment on games to clarify the source boundary.
-- --------------------------------------------------------------------------
COMMENT ON TABLE FLAT.games IS
$$One row per game. Wide format: both teams stats in one row. Source boundary: jb_seed covers 1946-Nov-01 through 2023-Jun-12 (end of 2022-23 NBA season); br_scrape covers 2023-Oct-24 onward (start of 2023-24 season). No overlap by season. game_id format differs by source: JB uses NBA Stats API numeric (e.g. 42200405) and BR uses URL slug (e.g. 202405190DEN). Join to player_box_basic on game_id — works within an era because the canonical source for that era's player_box_basic uses the same format.$$;

COMMENT ON TABLE FLAT.player_box_basic IS
$$One row per player per game. Basic box score stats. Source boundary: season <= 2023 (NBA seasons ending Jun-2023 and earlier) is jb_seed; season >= 2024 is br_scrape. No same-game duplication after the 2026-05-15 dedup + canonical-swap. Use this for player-level queries; for team-level totals use DERIVED.vw_team_box (sums basic stats grouped by game_id + team_id).$$;
