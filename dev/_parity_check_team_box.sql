-- Parity check: ZK_NBA.DERIVED.vw_team_box vs JB_HISTORIC_NBA.PUBLIC.TEAMSTATISTICS.
-- Run: .venv/bin/python dev/apply_sql.py dev/_parity_check_team_box.sql
-- Delete after view design is validated.
--
-- Reads results top-to-bottom:
--   Q1: Single-game spot-check (2023 NBA Finals Game 5). Diff each metric.
--   Q2: Wide-sample summary across 500 random games — counts of nonzero deltas
--       per metric. Zero deltas = parity. Nonzero = investigate.
--   Q3: Narrative-stats coverage census across all of TEAMSTATISTICS — tells
--       us what % of rows actually have BENCHPOINTS, LEADCHANGES, etc.
--   Q4: Minutes sanity check — every regulation game should sum to 240; OT
--       games to 240 + 25 × n_ot_periods.

USE ROLE DEVELOPER_ADMIN;
USE WAREHOUSE NBA_INGEST_WH;

-- --------------------------------------------------------------------------
-- Q1: Single-game parity (Finals Game 5, DEN @ MIA, 2023-06-12).
-- --------------------------------------------------------------------------
WITH joined AS (
    SELECT
        ours.team_id,
        ours.team_name,
        ours.pts            AS our_pts,    theirs.TEAMSCORE             AS jb_pts,
        ours.ast            AS our_ast,    theirs.ASSISTS               AS jb_ast,
        ours.reb            AS our_reb,    theirs.REBOUNDSTOTAL         AS jb_reb,
        ours.oreb           AS our_oreb,   theirs.REBOUNDSOFFENSIVE     AS jb_oreb,
        ours.dreb           AS our_dreb,   theirs.REBOUNDSDEFENSIVE     AS jb_dreb,
        ours.stl            AS our_stl,    theirs.STEALS                AS jb_stl,
        ours.blk            AS our_blk,    theirs.BLOCKS                AS jb_blk,
        ours.tov            AS our_tov,    theirs.TURNOVERS             AS jb_tov,
        ours.pf             AS our_pf,     theirs.FOULSPERSONAL         AS jb_pf,
        ours.fgm            AS our_fgm,    theirs.FIELDGOALSMADE        AS jb_fgm,
        ours.fga            AS our_fga,    theirs.FIELDGOALSATTEMPTED   AS jb_fga,
        ours.fg3m           AS our_fg3m,   theirs.THREEPOINTERSMADE     AS jb_fg3m,
        ours.fg3a           AS our_fg3a,   theirs.THREEPOINTERSATTEMPTED AS jb_fg3a,
        ours.ftm            AS our_ftm,    theirs.FREETHROWSMADE        AS jb_ftm,
        ours.fta            AS our_fta,    theirs.FREETHROWSATTEMPTED   AS jb_fta,
        ours.team_minutes   AS our_min,    theirs.NUMMINUTES            AS jb_min
    FROM ZK_NBA.DERIVED.vw_team_box ours
    JOIN JB_HISTORIC_NBA.PUBLIC.TEAMSTATISTICS theirs
      ON CAST(theirs.GAMEID AS STRING) = ours.game_id
     AND theirs.TEAMID = ours.team_id
    WHERE ours.game_id = '42200405'
)
SELECT
    team_id,
    team_name,
    (our_pts  - jb_pts)::INT    AS d_pts,
    (our_ast  - jb_ast)::INT    AS d_ast,
    (our_reb  - jb_reb)::INT    AS d_reb,
    (our_oreb - jb_oreb)::INT   AS d_oreb,
    (our_dreb - jb_dreb)::INT   AS d_dreb,
    (our_stl  - jb_stl)::INT    AS d_stl,
    (our_blk  - jb_blk)::INT    AS d_blk,
    (our_tov  - jb_tov)::INT    AS d_tov,
    (our_pf   - jb_pf)::INT     AS d_pf,
    (our_fgm  - jb_fgm)::INT    AS d_fgm,
    (our_fga  - jb_fga)::INT    AS d_fga,
    (our_fg3m - jb_fg3m)::INT   AS d_fg3m,
    (our_fg3a - jb_fg3a)::INT   AS d_fg3a,
    (our_ftm  - jb_ftm)::INT    AS d_ftm,
    (our_fta  - jb_fta)::INT    AS d_fta,
    (our_min  - jb_min)::INT    AS d_minutes
FROM joined
ORDER BY team_id;

-- --------------------------------------------------------------------------
-- Q2: Wide-sample mismatch counts across 500 games.
-- --------------------------------------------------------------------------
WITH sample_games AS (
    SELECT DISTINCT game_id FROM ZK_NBA.DERIVED.vw_team_box
    ORDER BY HASH(game_id)
    LIMIT 500
),
diffs AS (
    SELECT
        ours.game_id, ours.team_id,
        ours.pts - theirs.TEAMSCORE              AS d_pts,
        ours.ast - theirs.ASSISTS                AS d_ast,
        ours.reb - theirs.REBOUNDSTOTAL          AS d_reb,
        ours.oreb - theirs.REBOUNDSOFFENSIVE     AS d_oreb,
        ours.dreb - theirs.REBOUNDSDEFENSIVE     AS d_dreb,
        ours.stl - theirs.STEALS                 AS d_stl,
        ours.blk - theirs.BLOCKS                 AS d_blk,
        ours.tov - theirs.TURNOVERS              AS d_tov,
        ours.pf  - theirs.FOULSPERSONAL          AS d_pf,
        ours.fgm - theirs.FIELDGOALSMADE         AS d_fgm,
        ours.fga - theirs.FIELDGOALSATTEMPTED    AS d_fga,
        ours.fg3m - theirs.THREEPOINTERSMADE     AS d_fg3m,
        ours.fg3a - theirs.THREEPOINTERSATTEMPTED AS d_fg3a,
        ours.ftm - theirs.FREETHROWSMADE         AS d_ftm,
        ours.fta - theirs.FREETHROWSATTEMPTED    AS d_fta,
        ours.team_minutes - theirs.NUMMINUTES    AS d_min
    FROM ZK_NBA.DERIVED.vw_team_box ours
    JOIN JB_HISTORIC_NBA.PUBLIC.TEAMSTATISTICS theirs
      ON CAST(theirs.GAMEID AS STRING) = ours.game_id
     AND theirs.TEAMID = ours.team_id
    WHERE ours.game_id IN (SELECT game_id FROM sample_games)
)
SELECT
    COUNT(*) AS team_game_rows_compared,
    SUM(CASE WHEN d_pts  != 0 THEN 1 ELSE 0 END) AS mismatch_pts,
    SUM(CASE WHEN d_ast  != 0 THEN 1 ELSE 0 END) AS mismatch_ast,
    SUM(CASE WHEN d_reb  != 0 THEN 1 ELSE 0 END) AS mismatch_reb,
    SUM(CASE WHEN d_oreb != 0 THEN 1 ELSE 0 END) AS mismatch_oreb,
    SUM(CASE WHEN d_dreb != 0 THEN 1 ELSE 0 END) AS mismatch_dreb,
    SUM(CASE WHEN d_stl  != 0 THEN 1 ELSE 0 END) AS mismatch_stl,
    SUM(CASE WHEN d_blk  != 0 THEN 1 ELSE 0 END) AS mismatch_blk,
    SUM(CASE WHEN d_tov  != 0 THEN 1 ELSE 0 END) AS mismatch_tov,
    SUM(CASE WHEN d_pf   != 0 THEN 1 ELSE 0 END) AS mismatch_pf,
    SUM(CASE WHEN d_fgm  != 0 THEN 1 ELSE 0 END) AS mismatch_fgm,
    SUM(CASE WHEN d_fga  != 0 THEN 1 ELSE 0 END) AS mismatch_fga,
    SUM(CASE WHEN d_fg3m != 0 THEN 1 ELSE 0 END) AS mismatch_fg3m,
    SUM(CASE WHEN d_fg3a != 0 THEN 1 ELSE 0 END) AS mismatch_fg3a,
    SUM(CASE WHEN d_ftm  != 0 THEN 1 ELSE 0 END) AS mismatch_ftm,
    SUM(CASE WHEN d_fta  != 0 THEN 1 ELSE 0 END) AS mismatch_fta,
    SUM(CASE WHEN d_min  != 0 THEN 1 ELSE 0 END) AS mismatch_minutes
FROM diffs;

-- --------------------------------------------------------------------------
-- Q3: How much of TEAMSTATISTICS actually has the "narrative" columns populated?
-- --------------------------------------------------------------------------
SELECT
    COUNT(*)                                                    AS total_rows,
    COUNT(BENCHPOINTS)                                          AS has_benchpoints,
    COUNT(BIGGESTLEAD)                                          AS has_biggest_lead,
    COUNT(LEADCHANGES)                                          AS has_lead_changes,
    COUNT(POINTSINTHEPAINT)                                     AS has_paint_pts,
    COUNT(POINTSFASTBREAK)                                      AS has_fb_pts,
    COUNT(POINTSFROMTURNOVERS)                                  AS has_fto_pts,
    COUNT(POINTSSECONDCHANCE)                                   AS has_sc_pts,
    COUNT(TIMESTIED)                                            AS has_times_tied,
    COUNT(COACHID)                                              AS has_coach_id
FROM JB_HISTORIC_NBA.PUBLIC.TEAMSTATISTICS;

-- --------------------------------------------------------------------------
-- Q3b: When DO narrative stats appear? Date range for non-NULL BENCHPOINTS.
-- --------------------------------------------------------------------------
SELECT
    MIN(GAMEDATE) AS earliest_benchpoints_game,
    MAX(GAMEDATE) AS latest_benchpoints_game,
    COUNT(*)      AS games_with_benchpoints
FROM JB_HISTORIC_NBA.PUBLIC.TEAMSTATISTICS
WHERE BENCHPOINTS IS NOT NULL;

-- --------------------------------------------------------------------------
-- Q4: Minutes sanity — every regulation game should sum to 240 per team.
-- --------------------------------------------------------------------------
SELECT
    team_minutes,
    COUNT(*) AS team_game_rows
FROM ZK_NBA.DERIVED.vw_team_box
GROUP BY team_minutes
ORDER BY team_game_rows DESC
LIMIT 10;
