-- metric_coverage seed — authored from NBA tracking-start seasons (domain ground
-- truth) + BR publication boundaries verified in Phase 0. NOT derived from the
-- scrape: Phase 0 proved BR's column template is uniform across eras, so a
-- 1972-73 box shows STL/BLK/TOV headers with all-NaN cells. Column presence lies;
-- this table is the truth.
--
-- For the Phase 1 modern slice (2024-25) every metric is tracked — but we seed
-- the FULL-history coverage now so the registry is complete and correct from the
-- first row, and "Bill Russell had 0 steals" can never be answered.
--
-- Run after 010_ddl.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA_V2;
USE SCHEMA FLAT;
USE WAREHOUSE NBA_INGEST_WH;

INSERT INTO metric_coverage (metric, column_ref, first_tracked_season, status, null_means, authority) VALUES
    -- Always tracked since the BAA's first season (1946-47). On a player-game row, a NULL
    -- is NOT an era gap and NOT an ingestion gap — it means the player DID NOT PLAY (DNP/
    -- inactive). Cross-check minutes_played (NULL/0) + game_inactives. A NULL alongside
    -- minutes_played>0 WOULD be a real gap (anomaly worth flagging). Never 0 for not-recorded.
    ('pts',  'player_box_basic.pts / games.*_pts',     NULL, 'always',         'player-game NULL = player did not play (DNP/inactive); cross-check minutes_played (NULL/0) + game_inactives. NULL with minutes_played>0 = a real gap (anomaly). Never 0 for not-recorded.', 'tracked since 1946-47'),
    ('fg',   'player_box_basic.fgm/fga',               NULL, 'always',         'player-game NULL = player did not play (DNP/inactive); see minutes_played + game_inactives. NULL with minutes_played>0 = a real gap.', 'tracked since 1946-47'),
    ('ft',   'player_box_basic.ftm/fta',               NULL, 'always',         'player-game NULL = player did not play (DNP/inactive); see minutes_played + game_inactives. NULL with minutes_played>0 = a real gap.', 'tracked since 1946-47'),
    ('trb',  'player_box_basic.reb',                   NULL, 'always',         'Pre-1950-51: total rebounds not recorded (era). From 1950-51: player-game NULL = player did not play (DNP/inactive), per minutes_played + game_inactives.', 'total rebounds since 1950-51; treat pre-1951 as not recorded'),
    ('pf',   'player_box_basic.pf',                    NULL, 'always',         'player-game NULL = player did not play (DNP/inactive); see minutes_played + game_inactives. NULL with minutes_played>0 = a real gap.', 'tracked since 1946-47'),
    -- RECORDING RAMPS: these stats existed but old box scores logged them sparsely
    -- (Phase 4 audit: ast 58% NULL in 1960 -> 0% modern; mp 77% -> 19.5%; is_starter
    -- 98% -> 0%). A NULL = not-recorded-this-player/game, never 0. NOT 'always'.
    ('mp',         'player_box_basic.minutes_played',  NULL, 'recording_ramp', 'sparse in old box scores; NULL = not recorded, never 0', 'BR recording ramp (Phase 4 audit)'),
    ('ast',        'player_box_basic.ast',             NULL, 'recording_ramp', 'sparse in old box scores; NULL = not recorded, never 0', 'BR recording ramp (Phase 4 audit)'),
    ('is_starter', 'player_box_basic.is_starter',      NULL, 'recording_ramp', '"Reserves" separator absent in old box scores -> NULL (unknown); complete modern', 'BR format ramp (Phase 4 audit)'),
    ('arena_state','games.arena_state',                NULL, 'recording_ramp', 'old scorebox_meta lists "Arena, City" without state -> NULL; present modern', 'BR format ramp (Phase 4 audit)'),
    -- The 1973-74 tracking expansion.
    -- RAMP, not cliff: these stats EXISTED but were only sporadically recorded
    -- before the league-wide official season (Phase 3 survivor analysis found
    -- real but sparse pre-1974 steals/blocks/turnovers in BR — e.g. Wilt's blocks).
    ('stl',  'player_box_basic.stl',                   1974, 'official_complete_from', '(near-)complete from 1973-74; sporadic earlier (BR partial). A present pre-1974 value is REAL; a NULL is not-recorded-this-game, never 0.', 'NBA official 1973-74; ramp not cliff (Phase 3)'),
    ('blk',  'player_box_basic.blk',                   1974, 'official_complete_from', '(near-)complete from 1973-74; sporadic earlier. Present=REAL; NULL=not-recorded, never 0.', 'NBA official 1973-74; ramp (Phase 3)'),
    ('oreb', 'player_box_basic.oreb',                  1974, 'official_complete_from', '(near-)complete from 1973-74; sporadic earlier. Present=REAL; NULL=not-recorded, never 0.', 'NBA official 1973-74; ramp (Phase 3)'),
    ('dreb', 'player_box_basic.dreb',                  1974, 'official_complete_from', '(near-)complete from 1973-74; sporadic earlier. Present=REAL; NULL=not-recorded, never 0.', 'NBA official 1973-74; ramp (Phase 3)'),
    ('tov',  'player_box_basic.tov',                   1978, 'official_complete_from', '(near-)complete from 1977-78; sporadic earlier (BR partial). Present=REAL; NULL=not-recorded, never 0.', 'NBA official 1977-78; ramp (Phase 3)'),
    -- CLIFF: the 3-point shot did not exist before 1979-80 (contrast the ramp stats above).
    ('fg3',  'player_box_basic.fg3m/fg3a',             1980, 'did_not_exist_before', 'the 3-point line DID NOT EXIST before 1979-80; NULL=not-applicable, never 0.', 'NBA official: 3-point line introduced 1979-80 (true cliff)'),
    -- BR-published derived/aux metrics.
    ('game_score',        'player_box_basic.game_score', 1979, 'br_published_from', 'BR did not publish GmSc before ~1978-79', 'BR publication boundary'),
    ('plus_minus',        'player_box_basic.plus_minus', 1997, 'br_published_from', 'BR publishes +/- (play-by-play derived) from ~1996-97; NULL before, and NULL for DNP players within the tracked era.', 'BR publication boundary'),
    ('player_box_advanced','player_box_advanced.*',       1985, 'br_published_from', 'BR advanced box table not published before ~1985; derivable metrics inherit their inputs', 'BR publication boundary (Phase 0 verified)'),
    ('player_quarter_box', 'player_quarter_box.*',        2001, 'br_published_from', 'BR per-quarter tables absent in 1995, present by 2001; exact 1996-2000 boundary unpinned', 'BR publication boundary (Phase 0 verified)'),
    ('arena_name',         'games.arena_name',            1955, 'br_published_from', 'no scorebox meta block on pre-1955 BAA games', 'BR publication boundary (Phase 0 verified)'),
    ('game_officials',     'game_officials.*',            1995, 'br_published_from', 'referee anchor links only from 1995+; pre-1995 bare names are not extracted yet -> game_officials empty there (sparse, not wrong)', 'BR publication boundary (Phase 0 + Phase 3 verified)');
