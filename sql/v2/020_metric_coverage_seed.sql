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
    -- Always tracked since the BAA's first season (1946-47).
    ('pts',  'player_box_basic.pts / games.*_pts',     NULL, 'always',         NULL, 'tracked since 1946-47'),
    ('mp',   'player_box_basic.minutes_played',        NULL, 'always',         NULL, 'tracked since 1946-47'),
    ('fg',   'player_box_basic.fgm/fga',               NULL, 'always',         NULL, 'tracked since 1946-47'),
    ('ft',   'player_box_basic.ftm/fta',               NULL, 'always',         NULL, 'tracked since 1946-47'),
    ('trb',  'player_box_basic.reb',                   NULL, 'always',         NULL, 'total rebounds since 1950-51; treat pre-1951 as not recorded'),
    ('ast',  'player_box_basic.ast',                   NULL, 'always',         NULL, 'tracked since 1946-47'),
    ('pf',   'player_box_basic.pf',                    NULL, 'always',         NULL, 'tracked since 1946-47'),
    -- The 1973-74 tracking expansion.
    ('stl',  'player_box_basic.stl',                   1974, 'tracked_from',   'not recorded (NOT zero)', 'NBA official: steals became an official stat in 1973-74'),
    ('blk',  'player_box_basic.blk',                   1974, 'tracked_from',   'not recorded (NOT zero)', 'NBA official: blocks became an official stat in 1973-74'),
    ('oreb', 'player_box_basic.oreb',                  1974, 'tracked_from',   'not recorded (NOT zero)', 'NBA official: offensive rebounds split out in 1973-74'),
    ('dreb', 'player_box_basic.dreb',                  1974, 'tracked_from',   'not recorded (NOT zero)', 'NBA official: defensive rebounds split out in 1973-74'),
    -- Turnovers: 1977-78.
    ('tov',  'player_box_basic.tov',                   1978, 'tracked_from',   'not recorded (NOT zero)', 'NBA official: turnovers became an official stat in 1977-78'),
    -- The 3-point line: 1979-80.
    ('fg3',  'player_box_basic.fg3m/fg3a',             1980, 'tracked_from',   'did not exist (NOT zero) — no 3-pt line before 1979-80', 'NBA official: 3-point line introduced in 1979-80'),
    -- BR-published derived/aux metrics.
    ('game_score',        'player_box_basic.game_score', 1979, 'br_published_from', 'BR did not publish GmSc before ~1978-79', 'BR publication boundary'),
    ('player_box_advanced','player_box_advanced.*',       1985, 'br_published_from', 'BR advanced box table not published before ~1985; derivable metrics inherit their inputs', 'BR publication boundary (Phase 0 verified)'),
    ('player_quarter_box', 'player_quarter_box.*',        2001, 'br_published_from', 'BR per-quarter tables absent in 1995, present by 2001; exact 1996-2000 boundary unpinned', 'BR publication boundary (Phase 0 verified)'),
    ('arena_name',         'games.arena_name',            1955, 'br_published_from', 'no scorebox meta block on pre-1955 BAA games', 'BR publication boundary (Phase 0 verified)');
