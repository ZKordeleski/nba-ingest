-- ZK_NBA.DERIVED.vw_team_box
--
-- Team-level box score, one row per team per game. Computed at query time from
-- FLAT.player_box_basic via SUM(...) GROUP BY (game_id, team_id).
--
-- Purpose: provide JB-TEAMSTATISTICS-equivalent coverage for the columns that
-- ARE derivable from box-score data, without storing redundant aggregates. The
-- agent can join this view to FLAT.games or FLAT.line_scores for full team
-- context.
--
-- NOT in this view (require sources we don't ingest):
--   - BENCHPOINTS               (needs is_starter flag — not yet captured)
--   - BIGGESTLEAD / SCORINGRUN  (play-by-play derived)
--   - LEADCHANGES / TIMESTIED   (play-by-play derived)
--   - POINTSINTHEPAINT          (shot-location derived)
--   - POINTSFASTBREAK           (play-by-play derived)
--   - POINTSFROMTURNOVERS       (play-by-play derived)
--   - POINTSSECONDCHANCE        (play-by-play derived)
--   - TIMEOUTSREMAINING         (play-by-play derived)
--   - SEASONWINS / SEASONLOSSES (running record at game time — derivable via
--                                window function over games, deferred)
--   - COACHID                   (roster metadata, not in any source we ingest)
--
-- Empirical finding (2026-05-15): JB's TEAMSTATISTICS itself has NULL values
-- for these "narrative" columns in known modern games (e.g. 2023 NBA Finals
-- Game 5, gameid=42200405). So even calling this a "gap" overstates the case.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE SCHEMA DERIVED;
USE WAREHOUSE NBA_INGEST_WH;

CREATE OR REPLACE VIEW ZK_NBA.DERIVED.vw_team_box
COMMENT = 'Team-level box score per game, derived from FLAT.player_box_basic. One row per team per game. Use this for team totals — do NOT add an aggregate table. Coverage matches FLAT.player_box_basic (1946-present).'
AS
WITH agg AS (
    SELECT
        game_id,
        team_id,
        ANY_VALUE(team_name)         AS team_name,
        ANY_VALUE(team_abbr)         AS team_abbr,
        ANY_VALUE(opponent_team_name) AS opponent_team_name,
        ANY_VALUE(is_home)           AS is_home,
        ANY_VALUE(is_win)            AS is_win,
        ANY_VALUE(game_date)         AS game_date,
        ANY_VALUE(season)            AS season,
        ANY_VALUE(game_type)         AS game_type,
        SUM(pts)                     AS pts,
        SUM(ast)                     AS ast,
        SUM(reb)                     AS reb,
        SUM(oreb)                    AS oreb,
        SUM(dreb)                    AS dreb,
        SUM(stl)                     AS stl,
        SUM(blk)                     AS blk,
        SUM(tov)                     AS tov,
        SUM(pf)                      AS pf,
        SUM(fgm)                     AS fgm,
        SUM(fga)                     AS fga,
        SUM(fg3m)                    AS fg3m,
        SUM(fg3a)                    AS fg3a,
        SUM(ftm)                     AS ftm,
        SUM(fta)                     AS fta,
        SUM(minutes_played)          AS team_minutes,
        ANY_VALUE(source)            AS source,
        MAX(fetched_at)              AS fetched_at
    FROM ZK_NBA.FLAT.player_box_basic
    GROUP BY game_id, team_id
)
SELECT
    game_id,
    game_date,
    season,
    game_type,
    team_id,
    team_name,
    team_abbr,
    opponent_team_name,
    is_home,
    is_win,
    pts,
    ast,
    reb,
    oreb,
    dreb,
    stl,
    blk,
    tov,
    pf,
    fgm,
    fga,
    CASE WHEN fga  > 0 THEN fgm  / fga  ELSE NULL END AS fg_pct,
    fg3m,
    fg3a,
    CASE WHEN fg3a > 0 THEN fg3m / fg3a ELSE NULL END AS fg3_pct,
    ftm,
    fta,
    CASE WHEN fta  > 0 THEN ftm  / fta  ELSE NULL END AS ft_pct,
    team_minutes,
    source,
    fetched_at
FROM agg;
