-- nba-ingest FLAT tables.
-- Flattened relational tables with typed columns and column-level comments.
-- No derived metrics — agent computes analysis at query time.
--
-- Run after 020_raw_tables.sql.
-- Source: JB_HISTORIC_NBA seed (1946-2025) + Basketball-Reference (2023-present).

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

-- --------------------------------------------------------------------------
-- games
-- Grain: one row per game. Wide format: both teams' box stats in one row.
-- Source: JB_HISTORIC_NBA.PUBLIC.GAME (1946-Jun 2023) + BR scrape (2023-present).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.games (
    game_id              STRING  NOT NULL COMMENT 'NBA game ID (e.g. 42200405). String to preserve leading zeros if any.',
    game_date            DATE    NOT NULL COMMENT 'Calendar date the game was played.',
    season               INT              COMMENT 'Season end year (e.g. 2023 for 2022-23 season).',
    season_id            INT              COMMENT 'NBA season-type-prefixed season code. JB: from GAME.SEASON_ID (22022 = 2022-23 regular, 42022 = playoffs). BR: derived as <first digit of game_id> || LPAD(season-1, 4, ''0'') — same format.',
    season_type          STRING           COMMENT 'Regular Season | Playoffs | Play In | Preseason',
    home_team_id         INT              COMMENT 'NBA Stats API team ID for the home team. JB: from GAME.TEAM_ID_HOME directly. BR: resolved post-MERGE from home_team_abbr via FLAT.teams lookup with BR->NBA translation (BRK->BKN, CHO->CHA, PHO->PHX).',
    home_team_abbr       STRING           COMMENT 'Home team abbreviation. JB: NBA style (DEN, BKN, CHA, PHX). BR: BR style (DEN, BRK, CHO, PHO). Use team_id for cross-source joins; team_abbr is display-only.',
    away_team_id         INT              COMMENT 'NBA Stats API team ID for the away team. Same resolution path as home_team_id.',
    away_team_abbr       STRING           COMMENT 'Away team abbreviation. Source-flavored same as home_team_abbr.',
    home_pts             INT              COMMENT 'Home team final score.',
    away_pts             INT              COMMENT 'Away team final score.',
    home_wl              STRING           COMMENT 'W or L from home team perspective.',
    home_fgm             INT              COMMENT 'Home field goals made.',
    home_fga             INT              COMMENT 'Home field goals attempted.',
    home_fg_pct          FLOAT            COMMENT 'Home field goal percentage.',
    home_fg3m            INT              COMMENT 'Home three-pointers made.',
    home_fg3a            INT              COMMENT 'Home three-pointers attempted.',
    home_fg3_pct         FLOAT            COMMENT 'Home three-point percentage.',
    home_ftm             INT              COMMENT 'Home free throws made.',
    home_fta             INT              COMMENT 'Home free throws attempted.',
    home_ft_pct          FLOAT            COMMENT 'Home free throw percentage.',
    home_oreb            INT              COMMENT 'Home offensive rebounds.',
    home_dreb            INT              COMMENT 'Home defensive rebounds.',
    home_reb             INT              COMMENT 'Home total rebounds.',
    home_ast             INT              COMMENT 'Home assists.',
    home_stl             INT              COMMENT 'Home steals.',
    home_blk             INT              COMMENT 'Home blocks.',
    home_tov             INT              COMMENT 'Home turnovers.',
    home_pf              INT              COMMENT 'Home personal fouls.',
    home_plus_minus      INT              COMMENT 'Home team plus/minus. JB: from GAME.PLUS_MINUS_HOME (NBA Stats API authoritative, may be 0 for legacy games). BR: derived as home_pts - away_pts.',
    away_fgm             INT              COMMENT 'Away field goals made.',
    away_fga             INT              COMMENT 'Away field goals attempted.',
    away_fg_pct          FLOAT            COMMENT 'Away field goal percentage.',
    away_fg3m            INT              COMMENT 'Away three-pointers made.',
    away_fg3a            INT              COMMENT 'Away three-pointers attempted.',
    away_fg3_pct         FLOAT            COMMENT 'Away three-point percentage.',
    away_ftm             INT              COMMENT 'Away free throws made.',
    away_fta             INT              COMMENT 'Away free throws attempted.',
    away_ft_pct          FLOAT            COMMENT 'Away free throw percentage.',
    away_oreb            INT              COMMENT 'Away offensive rebounds.',
    away_dreb            INT              COMMENT 'Away defensive rebounds.',
    away_reb             INT              COMMENT 'Away total rebounds.',
    away_ast             INT              COMMENT 'Away assists.',
    away_stl             INT              COMMENT 'Away steals.',
    away_blk             INT              COMMENT 'Away blocks.',
    away_tov             INT              COMMENT 'Away turnovers.',
    away_pf              INT              COMMENT 'Away personal fouls.',
    away_plus_minus      INT              COMMENT 'Away team plus/minus. JB: NBA Stats API value. BR: derived as away_pts - home_pts.',
    source               STRING           COMMENT 'jb_seed | br_scrape — which pipeline wrote this row.',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (game_id)
)
COMMENT = 'One row per game. Wide format: both teams stats in one row. Source boundary: jb_seed covers 1946-Nov through 2023-Jun-12 (end of 2022-23 NBA season); br_scrape covers 2023-Oct onward. No overlap. game_id format differs by source: JB uses NBA Stats API numeric (e.g. 42200405); BR uses URL slug (e.g. 202405190DEN). Join to player_box_basic on game_id works within an era because both sides use the canonical source per era.';

-- --------------------------------------------------------------------------
-- player_box_basic
-- Grain: one row per player per game.
-- Source: JB PLAYERSTATISTICS1+2 union (1946-Apr 2025) + BR scrape (ongoing).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.player_box_basic (
    game_id              STRING  NOT NULL COMMENT 'NBA game ID. Join to games.game_id.',
    player_id            STRING  NOT NULL COMMENT 'Canonical NBA Stats API player ID. JB seed: PERSONID directly. BR scrape: resolved from BR slug via DERIVED.player_xref (name match against JB seed, fallback fetch of BR player page external link to stats.nba.com).',
    player_name          STRING           COMMENT 'Full player name (first + last). May have diacritics from BR (Jokić), ASCII from JB (Jokic).',
    br_player_slug       STRING           COMMENT 'BR player slug (e.g., wembavi01). Populated for source=br_scrape rows; NULL for JB seed. Diagnostic only — use player_id for joins.',
    team_id              INT              COMMENT 'NBA Stats API team ID for the player''s team this game. JB seed: resolved via JOIN to FLAT.team_history on (city || '' '' || nickname) with date-range filter (handles historical renames). BR scrape: resolved post-MERGE from team_abbr via FLAT.teams with BR->NBA translation. ~1.65% NULL on pre-1965 BAA/defunct franchises (Syracuse Nationals, etc.) where team_history doesn''t extend.',
    team_name            STRING           COMMENT 'Player''s team full name (city + nickname). JB seed: PLAYERTEAMCITY || '' '' || PLAYERTEAMNAME (historical names possible). BR scrape: FLAT.teams.full_name lookup (always current franchise name).',
    team_abbr            STRING           COMMENT 'Player''s team abbreviation. JB: NBA style (DEN, BKN, etc.). BR: BR style (DEN, BRK, etc.). Display-only — use team_id for cross-source joins.',
    opponent_team_name   STRING           COMMENT 'Opposing team full name. JB: OPPONENTTEAMCITY || '' '' || OPPONENTTEAMNAME. BR: derived post-MERGE by joining games on game_id and picking the OTHER team.',
    game_date            DATE             COMMENT 'Calendar date of the game.',
    season               INT              COMMENT 'NBA season end year (e.g. 2023 = 2022-23 season). Derived: MONTH(game_date) >= 10 ? YEAR+1 : YEAR. Boundary: jb_seed has season <= 2023; br_scrape has season >= 2024.',
    game_type            STRING           COMMENT 'One of: Regular Season, Playoffs, Play-in Tournament, NBA Cup, NBA Emirates Cup, Preseason. JB: from GAMETYPE directly. BR: derived from first digit of game_id (2=Regular, 4=Playoffs, 5=Play-in, 6=NBA Cup, 0/1=Preseason).',
    is_win               BOOLEAN          COMMENT 'True if the player''s team won this game.',
    is_home              BOOLEAN          COMMENT 'True if the player''s team was the home team.',
    minutes_played       FLOAT            COMMENT 'Minutes played as INT (rounded from NBA''s MM:SS internal format). DNP: NULL or 0. Sum over a team for regulation is typically 235-240 (rounding loss across 5 players), not exactly 240.',
    pts                  INT              COMMENT 'Points scored.',
    ast                  INT              COMMENT 'Assists.',
    reb                  INT              COMMENT 'Total rebounds.',
    oreb                 INT              COMMENT 'Offensive rebounds.',
    dreb                 INT              COMMENT 'Defensive rebounds.',
    stl                  INT              COMMENT 'Steals.',
    blk                  INT              COMMENT 'Blocks.',
    tov                  INT              COMMENT 'Turnovers.',
    pf                   INT              COMMENT 'Personal fouls.',
    fgm                  INT              COMMENT 'Field goals made.',
    fga                  INT              COMMENT 'Field goals attempted.',
    fg_pct               FLOAT            COMMENT 'Field goal percentage. Null if fga = 0.',
    fg3m                 INT              COMMENT 'Three-pointers made.',
    fg3a                 INT              COMMENT 'Three-pointers attempted.',
    fg3_pct              FLOAT            COMMENT 'Three-point percentage. Null if fg3a = 0.',
    ftm                  INT              COMMENT 'Free throws made.',
    fta                  INT              COMMENT 'Free throws attempted.',
    ft_pct               FLOAT            COMMENT 'Free throw percentage. Null if fta = 0.',
    plus_minus           FLOAT            COMMENT 'Plus/minus for the game.',
    source               STRING           COMMENT 'jb_seed | br_scrape',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (game_id, player_id)
)
COMMENT = 'One row per player per game. Basic box score stats. Source boundary: season <= 2023 = jb_seed; season >= 2024 = br_scrape. No same-game duplication. For team-level totals use DERIVED.vw_team_box. For advanced stats, join to player_box_advanced on (game_id, player_id).';

-- --------------------------------------------------------------------------
-- player_box_advanced
-- Grain: one row per player per game (BR only; null for pre-2023 games).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.player_box_advanced (
    game_id              STRING  NOT NULL COMMENT 'Join to player_box_basic on (game_id, player_id).',
    player_id            STRING  NOT NULL COMMENT 'Canonical NBA Stats API player ID. Resolved same way as player_box_basic.player_id — see that column''s comment.',
    br_player_slug       STRING           COMMENT 'BR player slug. Populated for BR-scraped rows; diagnostic only.',
    ts_pct               FLOAT            COMMENT 'True shooting percentage. (PTS / (2 * (FGA + 0.44 * FTA)))',
    efg_pct              FLOAT            COMMENT 'Effective field goal percentage. ((FGM + 0.5 * FG3M) / FGA)',
    fg3a_rate            FLOAT            COMMENT '3-point attempt rate (FG3A / FGA).',
    fta_rate             FLOAT            COMMENT 'Free throw attempt rate (FTA / FGA).',
    orb_pct              FLOAT            COMMENT 'Offensive rebound percentage.',
    drb_pct              FLOAT            COMMENT 'Defensive rebound percentage.',
    trb_pct              FLOAT            COMMENT 'Total rebound percentage.',
    ast_pct              FLOAT            COMMENT 'Assist percentage (% of teammate FGM assisted while on floor).',
    stl_pct              FLOAT            COMMENT 'Steal percentage.',
    blk_pct              FLOAT            COMMENT 'Block percentage.',
    tov_pct              FLOAT            COMMENT 'Turnover percentage.',
    usg_pct              FLOAT            COMMENT 'Usage percentage.',
    ortg                 INT              COMMENT 'Offensive rating (points produced per 100 possessions).',
    drtg                 INT              COMMENT 'Defensive rating (points allowed per 100 possessions).',
    bpm                  FLOAT            COMMENT 'Box plus/minus.',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (game_id, player_id)
)
COMMENT = 'Advanced box score stats per player per game. BR scrape only — not available from JB. Available for 2023-24 season onward (Slice 2+). Historical backfill (2001-2023) is Slice 4 scope.';

-- --------------------------------------------------------------------------
-- line_scores
-- Grain: one row per game (home+away in one wide row).
-- Source: JB LINE_SCORE + BR scrape (line_score hidden table).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.line_scores (
    game_id              STRING  NOT NULL COMMENT 'Join to games.game_id.',
    game_date            DATE             COMMENT 'Calendar date of the game.',
    home_team_abbr       STRING           COMMENT 'Home team abbreviation.',
    home_q1              INT              COMMENT 'Home team Q1 points.',
    home_q2              INT              COMMENT 'Home team Q2 points.',
    home_q3              INT              COMMENT 'Home team Q3 points.',
    home_q4              INT              COMMENT 'Home team Q4 points.',
    home_ot1             INT              COMMENT 'Home team OT1 points. Null if no overtime.',
    home_ot2             INT              COMMENT 'Home team OT2 points. Null if game ended before OT2.',
    home_ot3             INT              COMMENT 'Home team OT3 points. Null if game ended before OT3.',
    home_ot4             INT              COMMENT 'Home team OT4 points. Null if game ended before OT4.',
    home_pts             INT              COMMENT 'Home team total points (sum of all periods).',
    away_team_abbr       STRING           COMMENT 'Away team abbreviation.',
    away_q1              INT              COMMENT 'Away team Q1 points.',
    away_q2              INT              COMMENT 'Away team Q2 points.',
    away_q3              INT              COMMENT 'Away team Q3 points.',
    away_q4              INT              COMMENT 'Away team Q4 points.',
    away_ot1             INT              COMMENT 'Away team OT1 points. Null if no overtime.',
    away_ot2             INT              COMMENT 'Away team OT2 points. Null if game ended before OT2.',
    away_ot3             INT              COMMENT 'Away team OT3 points. Null if game ended before OT3.',
    away_ot4             INT              COMMENT 'Away team OT4 points. Null if game ended before OT4.',
    away_pts             INT              COMMENT 'Away team total points.',
    source               STRING           COMMENT 'jb_seed | br_scrape',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (game_id)
)
COMMENT = 'Quarter-by-quarter scoring. One row per game (home + away wide). Source: JB LINE_SCORE (modern) + BR scrape (2023-present). JB LINE_SCORE coverage date unknown — check MIN(game_date) after seeding.';

-- --------------------------------------------------------------------------
-- game_officials
-- Grain: one row per official per game.
-- Source: JB OFFICIALS (modern only, ~23,575 games).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.game_officials (
    game_id              STRING  NOT NULL COMMENT 'Join to games.game_id.',
    official_id          STRING  NOT NULL COMMENT 'Canonical NBA Stats API official ID (stringified). JB seed: OFFICIAL_ID directly cast to STRING. BR scrape: resolved from BR referee slug via DERIVED.official_xref (name match against JB; fallback to BR slug if unresolvable). Was INT in pre-decision-2 schema.',
    br_official_slug     STRING           COMMENT 'BR referee slug (e.g., davisma99r). Populated for BR-scraped rows; diagnostic only.',
    first_name           STRING           COMMENT 'Official''s first name.',
    last_name            STRING           COMMENT 'Official''s last name.',
    jersey_num           INT              COMMENT 'Official''s jersey number.',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (game_id, official_id)
)
COMMENT = 'Referee assignments per game. One row per official per game. Source: JB OFFICIALS (1946-Jun 2023) + BR scrape (2023-present). official_id is STRING to accommodate both JB''s NBA Stats API integer IDs (cast to string) and unresolvable BR slugs.';

-- --------------------------------------------------------------------------
-- game_inactives
-- Grain: one row per inactive player per game.
-- Source: JB INACTIVE_PLAYERS (modern only).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.game_inactives (
    game_id              STRING  NOT NULL COMMENT 'Join to games.game_id.',
    player_id            STRING  NOT NULL COMMENT 'Canonical NBA Stats API player ID. JB seed: PLAYER_ID cast to STRING. BR scrape: resolved via DERIVED.player_xref (same resolver as player_box_basic). Was INT before decision #3.',
    br_player_slug       STRING           COMMENT 'BR player slug. Populated for BR-scraped rows; diagnostic only.',
    first_name           STRING           COMMENT 'Player''s first name.',
    last_name            STRING           COMMENT 'Player''s last name.',
    jersey_num           INT              COMMENT 'Player''s jersey number. NULL for BR-scraped rows (not in meta block).',
    team_id              INT              COMMENT 'NBA Stats API team ID the player was rostered on. JB: from INACTIVE_PLAYERS.TEAM_ID. BR: resolved post-MERGE from team_abbr via FLAT.teams lookup with BR->NBA translation.',
    team_abbr            STRING           COMMENT 'Team abbreviation.',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (game_id, player_id)
)
COMMENT = 'Players listed as inactive (injured, rested, etc.) for a given game. Source: JB INACTIVE_PLAYERS — modern games only.';

-- --------------------------------------------------------------------------
-- players
-- Grain: one row per player (current career record).
-- Source: JB PLAYERS2 (6,533 players).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.players (
    player_id            STRING  NOT NULL COMMENT 'NBA player ID (PERSONID from JB).',
    first_name           STRING           COMMENT 'Player''s first name.',
    last_name            STRING           COMMENT 'Player''s last name.',
    birth_date           DATE             COMMENT 'Date of birth.',
    college              STRING           COMMENT 'College or university attended (may be null for international players).',
    country              STRING           COMMENT 'Country of origin.',
    height_in            FLOAT            COMMENT 'Height in inches.',
    weight_lb            FLOAT            COMMENT 'Weight in pounds.',
    position             STRING           COMMENT 'Primary position: G | F | C | G-F | F-C | etc.',
    draft_year           INT              COMMENT 'Year drafted. Null if undrafted.',
    draft_round          INT              COMMENT 'Draft round (1 or 2). Null if undrafted.',
    draft_pick           INT              COMMENT 'Pick number within the round. Null if undrafted.',
    from_year            INT              COMMENT 'First NBA season year.',
    to_year              INT              COMMENT 'Last NBA season year (may be current).',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (player_id)
)
COMMENT = 'One row per NBA player. Source: JB PLAYERS2. Covers 6,533 players — all who appeared in NBA box scores in the JB dataset. Join to player_box_basic on player_id.';

-- --------------------------------------------------------------------------
-- teams
-- Grain: one row per current team (30 teams).
-- Source: JB TEAM + TEAM_DETAILS (25/30); 5 supplemented from BR.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.teams (
    team_id              INT     NOT NULL COMMENT 'NBA team ID.',
    abbreviation         STRING           COMMENT 'Team abbreviation (NBA style, e.g. DEN, MIA, BOS).',
    full_name            STRING           COMMENT 'Full team name (e.g. Denver Nuggets).',
    city                 STRING           COMMENT 'Team city.',
    year_founded         INT              COMMENT 'Year the franchise was founded (or relocated to current city).',
    arena                STRING           COMMENT 'Current arena name. Null for 5 teams missing from JB TEAM_DETAILS (filled from BR in Slice 1 manual step).',
    arena_capacity       INT              COMMENT 'Arena seating capacity. Null for 5 teams missing from JB.',
    head_coach           STRING           COMMENT 'Current head coach as of seed date. Null for 5 teams missing from JB. May be stale — coaches change.',
    g_league_affiliate   STRING           COMMENT 'G League affiliate team name. Null for 5 teams missing from JB.',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (team_id)
)
COMMENT = 'One row per current NBA team (30 teams). Source: JB TEAM + TEAM_DETAILS joined. TEAM_DETAILS was missing ORL, NYK, BOS, CLE, NOP in JB — those 5 rows supplemented manually from BR after seed.';

-- --------------------------------------------------------------------------
-- team_history
-- Grain: one row per team-name-era (city/nickname changes and relocations).
-- Source: JB TEAMHISTORIES (140 rows).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.team_history (
    team_id              INT     NOT NULL COMMENT 'NBA team ID (links to current teams.team_id).',
    city                 STRING           COMMENT 'City the team played in during this era.',
    nickname             STRING           COMMENT 'Team nickname during this era (e.g. Supersonics, Bullets).',
    year_founded         INT              COMMENT 'First year of this era (in this city/name).',
    year_active_till     INT              COMMENT 'Last year of this era. Null if still active.',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.'
)
COMMENT = 'Team relocation and name-change history. One row per era. Source: JB TEAMHISTORIES (140 rows). Example: Seattle SuperSonics (1967-2008) → Oklahoma City Thunder (2008-present).';

-- --------------------------------------------------------------------------
-- draft
-- Grain: one row per draft pick.
-- Source: JB DRAFT_HISTORY (1947-2023) + BR scrape (2024-2025 in Slice 5).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.draft (
    person_id            INT              COMMENT 'NBA player ID for this pick.',
    player_name          STRING           COMMENT 'Player name at draft time.',
    season               INT     NOT NULL COMMENT 'Draft year (e.g. 2023).',
    round_number         INT              COMMENT '1 or 2.',
    round_pick           INT              COMMENT 'Pick number within the round.',
    overall_pick         INT     NOT NULL COMMENT 'Overall pick number (1-60).',
    draft_type           STRING           COMMENT 'Standard | Special | Expansion | etc.',
    team_id              INT              COMMENT 'Team that made the pick.',
    team_abbr            STRING           COMMENT 'Team abbreviation.',
    organization         STRING           COMMENT 'College, international team, or other organization.',
    organization_type    STRING           COMMENT 'College/University | G League | International | High School | etc.',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (season, overall_pick)
)
COMMENT = 'NBA draft history. One row per pick. Source: JB DRAFT_HISTORY (1947-2023). 2024-2025 classes to be added in Slice 5 from BR. Join to players on person_id.';

-- --------------------------------------------------------------------------
-- draft_combine
-- Grain: one row per combine participant per season.
-- Source: JB DRAFT_COMBINE_STATS (~1,202 rows).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.draft_combine (
    player_id            STRING           COMMENT 'NBA player ID.',
    player_name          STRING           COMMENT 'Player name.',
    season               INT              COMMENT 'Draft year.',
    position             STRING           COMMENT 'Position.',
    height               FLOAT            COMMENT 'Height without shoes (inches).',
    weight               FLOAT            COMMENT 'Weight (lbs).',
    wingspan             FLOAT            COMMENT 'Wingspan (inches).',
    standing_reach       FLOAT            COMMENT 'Standing reach (inches).',
    hand_length          FLOAT            COMMENT 'Hand length (inches).',
    hand_width           FLOAT            COMMENT 'Hand width (inches).',
    standing_vert        FLOAT            COMMENT 'Standing vertical leap (inches).',
    max_vert             FLOAT            COMMENT 'Max vertical leap (inches).',
    bench                INT              COMMENT 'Bench press reps at 185 lbs.',
    lane_agility         FLOAT            COMMENT 'Lane agility time (seconds).',
    shuttle_run          FLOAT            COMMENT 'Shuttle run time (seconds).',
    three_quarter_sprint FLOAT            COMMENT 'Three-quarter court sprint time (seconds).',
    spot_up_pct          FLOAT            COMMENT 'Spot up shooting percentage.',
    off_drib_pct         FLOAT            COMMENT 'Off-dribble shooting percentage.',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.'
)
COMMENT = 'NBA Draft Combine measurements. One row per participant per year. Source: JB DRAFT_COMBINE_STATS. Note: run DESCRIBE TABLE JB_HISTORIC_NBA.PUBLIC.DRAFT_COMBINE_STATS to verify column names before running the seed CTAS.';

-- --------------------------------------------------------------------------
-- play_by_play
-- Grain: one row per play-by-play event.
-- Source: JB PLAY_BY_PLAY_PART001 UNION PLAY_BY_PLAY_PART002 (~2.4M rows).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.play_by_play (
    game_id              STRING  NOT NULL COMMENT 'Join to games.game_id.',
    event_num            INT     NOT NULL COMMENT 'Sequential event number within the game.',
    event_type           INT              COMMENT 'NBA event message type code (EVENTMSGTYPE).',
    event_action_type    INT              COMMENT 'NBA event message action type code (EVENTMSGACTIONTYPE).',
    period               INT              COMMENT 'Game period (1-4 = regulation, 5+ = overtime).',
    clock_wall           STRING           COMMENT 'Wall clock time string (WCTIMESTRING).',
    clock_game           STRING           COMMENT 'Game clock time string (PCTIMESTRING), e.g. 12:00.',
    home_description     STRING           COMMENT 'Description of the event from home team perspective.',
    visitor_description  STRING           COMMENT 'Description of the event from visitor team perspective.',
    neutral_description  STRING           COMMENT 'Neutral description (used for non-team events like officials, timeouts).',
    score                STRING           COMMENT 'Running score string at this event, e.g. 102 - 98.',
    score_margin         STRING           COMMENT 'Score margin at this event (positive = home leading).',
    player1_id           INT              COMMENT 'Primary player involved in the event.',
    player1_name         STRING           COMMENT 'Primary player name.',
    player1_team_abbr    STRING           COMMENT 'Primary player''s team abbreviation.',
    player2_id           INT              COMMENT 'Secondary player (e.g. assist on a made basket).',
    player2_name         STRING           COMMENT 'Secondary player name.',
    player2_team_abbr    STRING           COMMENT 'Secondary player''s team abbreviation.',
    player3_id           INT              COMMENT 'Tertiary player (rare — used for flagrant fouls, etc.).',
    player3_name         STRING           COMMENT 'Tertiary player name.',
    player3_team_abbr    STRING           COMMENT 'Tertiary player''s team abbreviation.',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written.',

    PRIMARY KEY (game_id, event_num)
)
COMMENT = 'Play-by-play event log. One row per event. Source: JB PLAY_BY_PLAY_PART001 UNION PLAY_BY_PLAY_PART002 (~2.4M rows after dedup). UNION (not UNION ALL) handles the 1 game that appears in both parts. Coverage is modern games only (~5,300 games).';

-- --------------------------------------------------------------------------
-- draft_career_stats
-- Grain: one row per draft pick (annually refreshed from BR).
-- Source: BR /draft/NBA_{year}.html (Slice 5 — weekly_meta job).
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE ZK_NBA.FLAT.draft_career_stats (
    season               INT     NOT NULL COMMENT 'Draft year.',
    overall_pick         INT     NOT NULL COMMENT 'Overall pick number.',
    player_name          STRING           COMMENT 'Player name.',
    team_abbr            STRING           COMMENT 'Team that drafted this player.',
    college              STRING           COMMENT 'College or organization.',
    career_games         INT              COMMENT 'Career games played.',
    career_pts_per_game  FLOAT            COMMENT 'Career points per game.',
    career_reb_per_game  FLOAT            COMMENT 'Career rebounds per game.',
    career_ast_per_game  FLOAT            COMMENT 'Career assists per game.',
    career_fg_pct        FLOAT            COMMENT 'Career field goal percentage.',
    career_fg3_pct       FLOAT            COMMENT 'Career three-point percentage.',
    career_ft_pct        FLOAT            COMMENT 'Career free throw percentage.',
    career_win_shares    FLOAT            COMMENT 'Career win shares.',
    career_ws_per_48     FLOAT            COMMENT 'Career win shares per 48 minutes.',
    career_bpm           FLOAT            COMMENT 'Career box plus/minus.',
    career_vorp          FLOAT            COMMENT 'Career value over replacement player.',
    fetched_at           TIMESTAMP_NTZ    COMMENT 'Wall-clock time this row was written. Career stats are a snapshot at this time — the most recent row per (season, overall_pick) is current.',

    PRIMARY KEY (season, overall_pick)
)
COMMENT = 'Career stats for each draft pick, as reported on BR draft class pages. Updated weekly by the weekly_meta job. This is a MERGE target — each run upserts the latest career stats. Scope: Slice 5.';
