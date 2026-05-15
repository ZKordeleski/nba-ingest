"""Daily settle job (Slices A-D + G): settle BR boxscores into FLAT tables.

Modes (selected by env var):

    SETTLE_SLUG=202404090MEM
        Settle just this one game. Used for testing or backfilling a single
        known slug.

    SETTLE_DATE=2024-04-09
        Settle all games on this date. Use for backfilling a specific day.

    (neither set)
        Settle all games from yesterday. This is what the GitHub Actions cron
        invokes; "yesterday" is enough lead time that all games have ended
        and BR has published box scores.

Writes 4 FLAT tables per game (Slices A-D):
    games, player_box_basic, player_box_advanced, line_scores

Slices E (game_officials) and F (game_inactives) are deferred until the
officials-schema architectural decision (#2 in HANDOFF.md) is resolved.

All MERGEs are idempotent on their natural keys. Re-running on the same
date updates rows in place — no duplicates, fetched_at advances.

One Snowflake connection is shared across all games in a daily loop to
avoid 14× connect overhead.
"""

from __future__ import annotations

import json
import logging
import os
import tempfile
from datetime import date, datetime, timedelta
from pathlib import Path

from dotenv import load_dotenv

# Load .env for local CLI runs. override=False keeps CI-injected env vars
# (e.g. from GitHub Actions secrets) authoritative.
load_dotenv(Path(__file__).resolve().parents[3] / ".env", override=False)

from nba_ingest import snowflake_client
from nba_ingest.fetchers.boxscore import fetch_boxscore
from nba_ingest.fetchers.games import list_games_on_date
from nba_ingest.flatteners.boxscore import (
    flatten_game_row,
    flatten_line_score,
    flatten_player_box_advanced,
    flatten_player_box_basic,
)
from nba_ingest.resolvers.player_id import resolve_player_ids

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)

STAGE_PATH = "@ZK_NBA.RAW.INGEST_STAGE/flat"

GAMES_MERGE_SQL = f"""
MERGE INTO ZK_NBA.FLAT.games AS target
USING (
    SELECT
        $1:game_id::STRING            AS game_id,
        $1:game_date::DATE            AS game_date,
        $1:season::INT                AS season,
        $1:season_id::INT             AS season_id,
        $1:season_type::STRING        AS season_type,
        $1:home_team_id::INT          AS home_team_id,
        $1:home_team_abbr::STRING     AS home_team_abbr,
        $1:away_team_id::INT          AS away_team_id,
        $1:away_team_abbr::STRING     AS away_team_abbr,
        $1:home_pts::INT              AS home_pts,
        $1:away_pts::INT              AS away_pts,
        $1:home_wl::STRING            AS home_wl,
        $1:home_fgm::INT              AS home_fgm,
        $1:home_fga::INT              AS home_fga,
        $1:home_fg_pct::FLOAT         AS home_fg_pct,
        $1:home_fg3m::INT             AS home_fg3m,
        $1:home_fg3a::INT             AS home_fg3a,
        $1:home_fg3_pct::FLOAT        AS home_fg3_pct,
        $1:home_ftm::INT              AS home_ftm,
        $1:home_fta::INT              AS home_fta,
        $1:home_ft_pct::FLOAT         AS home_ft_pct,
        $1:home_oreb::INT             AS home_oreb,
        $1:home_dreb::INT             AS home_dreb,
        $1:home_reb::INT              AS home_reb,
        $1:home_ast::INT              AS home_ast,
        $1:home_stl::INT              AS home_stl,
        $1:home_blk::INT              AS home_blk,
        $1:home_tov::INT              AS home_tov,
        $1:home_pf::INT               AS home_pf,
        $1:home_plus_minus::INT       AS home_plus_minus,
        $1:away_fgm::INT              AS away_fgm,
        $1:away_fga::INT              AS away_fga,
        $1:away_fg_pct::FLOAT         AS away_fg_pct,
        $1:away_fg3m::INT             AS away_fg3m,
        $1:away_fg3a::INT             AS away_fg3a,
        $1:away_fg3_pct::FLOAT        AS away_fg3_pct,
        $1:away_ftm::INT              AS away_ftm,
        $1:away_fta::INT              AS away_fta,
        $1:away_ft_pct::FLOAT         AS away_ft_pct,
        $1:away_oreb::INT             AS away_oreb,
        $1:away_dreb::INT             AS away_dreb,
        $1:away_reb::INT              AS away_reb,
        $1:away_ast::INT              AS away_ast,
        $1:away_stl::INT              AS away_stl,
        $1:away_blk::INT              AS away_blk,
        $1:away_tov::INT              AS away_tov,
        $1:away_pf::INT               AS away_pf,
        $1:away_plus_minus::INT       AS away_plus_minus,
        $1:source::STRING             AS source,
        $1:fetched_at::TIMESTAMP_NTZ  AS fetched_at
    FROM {{stage_file}}
    (FILE_FORMAT => 'ZK_NBA.RAW.JSON_FF')
) AS src
ON target.game_id = src.game_id
WHEN MATCHED THEN UPDATE SET
    game_date = src.game_date,
    season = src.season,
    season_id = src.season_id,
    season_type = src.season_type,
    home_team_id = src.home_team_id,
    home_team_abbr = src.home_team_abbr,
    away_team_id = src.away_team_id,
    away_team_abbr = src.away_team_abbr,
    home_pts = src.home_pts,
    away_pts = src.away_pts,
    home_wl = src.home_wl,
    home_fgm = src.home_fgm, home_fga = src.home_fga, home_fg_pct = src.home_fg_pct,
    home_fg3m = src.home_fg3m, home_fg3a = src.home_fg3a, home_fg3_pct = src.home_fg3_pct,
    home_ftm = src.home_ftm, home_fta = src.home_fta, home_ft_pct = src.home_ft_pct,
    home_oreb = src.home_oreb, home_dreb = src.home_dreb, home_reb = src.home_reb,
    home_ast = src.home_ast, home_stl = src.home_stl, home_blk = src.home_blk,
    home_tov = src.home_tov, home_pf = src.home_pf, home_plus_minus = src.home_plus_minus,
    away_fgm = src.away_fgm, away_fga = src.away_fga, away_fg_pct = src.away_fg_pct,
    away_fg3m = src.away_fg3m, away_fg3a = src.away_fg3a, away_fg3_pct = src.away_fg3_pct,
    away_ftm = src.away_ftm, away_fta = src.away_fta, away_ft_pct = src.away_ft_pct,
    away_oreb = src.away_oreb, away_dreb = src.away_dreb, away_reb = src.away_reb,
    away_ast = src.away_ast, away_stl = src.away_stl, away_blk = src.away_blk,
    away_tov = src.away_tov, away_pf = src.away_pf, away_plus_minus = src.away_plus_minus,
    source = src.source,
    fetched_at = src.fetched_at
WHEN NOT MATCHED THEN INSERT (
    game_id, game_date, season, season_id, season_type,
    home_team_id, home_team_abbr, away_team_id, away_team_abbr,
    home_pts, away_pts, home_wl,
    home_fgm, home_fga, home_fg_pct, home_fg3m, home_fg3a, home_fg3_pct,
    home_ftm, home_fta, home_ft_pct,
    home_oreb, home_dreb, home_reb, home_ast, home_stl, home_blk,
    home_tov, home_pf, home_plus_minus,
    away_fgm, away_fga, away_fg_pct, away_fg3m, away_fg3a, away_fg3_pct,
    away_ftm, away_fta, away_ft_pct,
    away_oreb, away_dreb, away_reb, away_ast, away_stl, away_blk,
    away_tov, away_pf, away_plus_minus,
    source, fetched_at
) VALUES (
    src.game_id, src.game_date, src.season, src.season_id, src.season_type,
    src.home_team_id, src.home_team_abbr, src.away_team_id, src.away_team_abbr,
    src.home_pts, src.away_pts, src.home_wl,
    src.home_fgm, src.home_fga, src.home_fg_pct, src.home_fg3m, src.home_fg3a, src.home_fg3_pct,
    src.home_ftm, src.home_fta, src.home_ft_pct,
    src.home_oreb, src.home_dreb, src.home_reb, src.home_ast, src.home_stl, src.home_blk,
    src.home_tov, src.home_pf, src.home_plus_minus,
    src.away_fgm, src.away_fga, src.away_fg_pct, src.away_fg3m, src.away_fg3a, src.away_fg3_pct,
    src.away_ftm, src.away_fta, src.away_ft_pct,
    src.away_oreb, src.away_dreb, src.away_reb, src.away_ast, src.away_stl, src.away_blk,
    src.away_tov, src.away_pf, src.away_plus_minus,
    src.source, src.fetched_at
)
"""


PLAYER_BOX_BASIC_MERGE_SQL = """
MERGE INTO ZK_NBA.FLAT.player_box_basic AS target
USING (
    SELECT
        $1:game_id::STRING              AS game_id,
        $1:player_id::STRING            AS player_id,
        $1:br_player_slug::STRING       AS br_player_slug,
        $1:player_name::STRING          AS player_name,
        $1:team_id::INT                 AS team_id,
        $1:team_name::STRING            AS team_name,
        $1:team_abbr::STRING            AS team_abbr,
        $1:opponent_team_name::STRING   AS opponent_team_name,
        $1:game_date::DATE              AS game_date,
        $1:season::INT                  AS season,
        $1:game_type::STRING            AS game_type,
        $1:is_win::BOOLEAN              AS is_win,
        $1:is_home::BOOLEAN             AS is_home,
        $1:minutes_played::FLOAT        AS minutes_played,
        $1:pts::INT                     AS pts,
        $1:ast::INT                     AS ast,
        $1:reb::INT                     AS reb,
        $1:oreb::INT                    AS oreb,
        $1:dreb::INT                    AS dreb,
        $1:stl::INT                     AS stl,
        $1:blk::INT                     AS blk,
        $1:tov::INT                     AS tov,
        $1:pf::INT                      AS pf,
        $1:fgm::INT                     AS fgm,
        $1:fga::INT                     AS fga,
        $1:fg_pct::FLOAT                AS fg_pct,
        $1:fg3m::INT                    AS fg3m,
        $1:fg3a::INT                    AS fg3a,
        $1:fg3_pct::FLOAT               AS fg3_pct,
        $1:ftm::INT                     AS ftm,
        $1:fta::INT                     AS fta,
        $1:ft_pct::FLOAT                AS ft_pct,
        $1:plus_minus::FLOAT            AS plus_minus,
        $1:source::STRING               AS source,
        $1:fetched_at::TIMESTAMP_NTZ    AS fetched_at
    FROM {stage_file}
    (FILE_FORMAT => 'ZK_NBA.RAW.JSON_FF')
) AS src
-- MERGE on (game_id, player_id) — the natural PK. With decision #3, player_id
-- is now a real NBA Stats API id resolved at write time, so NULL = NULL
-- collisions can't happen.
ON target.game_id = src.game_id AND target.player_id = src.player_id
WHEN MATCHED THEN UPDATE SET
    br_player_slug = src.br_player_slug,
    player_name = src.player_name,
    team_abbr = src.team_abbr,
    game_date = src.game_date,
    is_home = src.is_home,
    minutes_played = src.minutes_played,
    pts = src.pts, ast = src.ast, reb = src.reb, oreb = src.oreb, dreb = src.dreb,
    stl = src.stl, blk = src.blk, tov = src.tov, pf = src.pf,
    fgm = src.fgm, fga = src.fga, fg_pct = src.fg_pct,
    fg3m = src.fg3m, fg3a = src.fg3a, fg3_pct = src.fg3_pct,
    ftm = src.ftm, fta = src.fta, ft_pct = src.ft_pct,
    plus_minus = src.plus_minus,
    source = src.source,
    fetched_at = src.fetched_at
WHEN NOT MATCHED THEN INSERT (
    game_id, player_id, br_player_slug, player_name, team_id, team_name, team_abbr,
    opponent_team_name, game_date, season, game_type, is_win, is_home,
    minutes_played, pts, ast, reb, oreb, dreb, stl, blk, tov, pf,
    fgm, fga, fg_pct, fg3m, fg3a, fg3_pct, ftm, fta, ft_pct,
    plus_minus, source, fetched_at
) VALUES (
    src.game_id, src.player_id, src.br_player_slug, src.player_name, src.team_id, src.team_name, src.team_abbr,
    src.opponent_team_name, src.game_date, src.season, src.game_type, src.is_win, src.is_home,
    src.minutes_played, src.pts, src.ast, src.reb, src.oreb, src.dreb, src.stl, src.blk, src.tov, src.pf,
    src.fgm, src.fga, src.fg_pct, src.fg3m, src.fg3a, src.fg3_pct, src.ftm, src.fta, src.ft_pct,
    src.plus_minus, src.source, src.fetched_at
)
"""


PLAYER_BOX_ADVANCED_MERGE_SQL = """
MERGE INTO ZK_NBA.FLAT.player_box_advanced AS target
USING (
    SELECT
        $1:game_id::STRING              AS game_id,
        $1:player_id::STRING            AS player_id,
        $1:br_player_slug::STRING       AS br_player_slug,
        $1:ts_pct::FLOAT                AS ts_pct,
        $1:efg_pct::FLOAT               AS efg_pct,
        $1:fg3a_rate::FLOAT             AS fg3a_rate,
        $1:fta_rate::FLOAT              AS fta_rate,
        $1:orb_pct::FLOAT               AS orb_pct,
        $1:drb_pct::FLOAT               AS drb_pct,
        $1:trb_pct::FLOAT               AS trb_pct,
        $1:ast_pct::FLOAT               AS ast_pct,
        $1:stl_pct::FLOAT               AS stl_pct,
        $1:blk_pct::FLOAT               AS blk_pct,
        $1:tov_pct::FLOAT               AS tov_pct,
        $1:usg_pct::FLOAT               AS usg_pct,
        $1:ortg::INT                    AS ortg,
        $1:drtg::INT                    AS drtg,
        $1:bpm::FLOAT                   AS bpm,
        $1:fetched_at::TIMESTAMP_NTZ    AS fetched_at
    FROM {stage_file}
    (FILE_FORMAT => 'ZK_NBA.RAW.JSON_FF')
) AS src
-- player_id is the resolved NBA Stats API id (decision #3).
ON target.game_id = src.game_id AND target.player_id = src.player_id
WHEN MATCHED THEN UPDATE SET
    br_player_slug = src.br_player_slug,
    ts_pct = src.ts_pct, efg_pct = src.efg_pct,
    fg3a_rate = src.fg3a_rate, fta_rate = src.fta_rate,
    orb_pct = src.orb_pct, drb_pct = src.drb_pct, trb_pct = src.trb_pct,
    ast_pct = src.ast_pct, stl_pct = src.stl_pct, blk_pct = src.blk_pct,
    tov_pct = src.tov_pct, usg_pct = src.usg_pct,
    ortg = src.ortg, drtg = src.drtg, bpm = src.bpm,
    fetched_at = src.fetched_at
WHEN NOT MATCHED THEN INSERT (
    game_id, player_id, br_player_slug,
    ts_pct, efg_pct, fg3a_rate, fta_rate,
    orb_pct, drb_pct, trb_pct, ast_pct, stl_pct, blk_pct, tov_pct, usg_pct,
    ortg, drtg, bpm, fetched_at
) VALUES (
    src.game_id, src.player_id, src.br_player_slug,
    src.ts_pct, src.efg_pct, src.fg3a_rate, src.fta_rate,
    src.orb_pct, src.drb_pct, src.trb_pct, src.ast_pct, src.stl_pct, src.blk_pct, src.tov_pct, src.usg_pct,
    src.ortg, src.drtg, src.bpm, src.fetched_at
)
"""


LINE_SCORES_MERGE_SQL = """
MERGE INTO ZK_NBA.FLAT.line_scores AS target
USING (
    SELECT
        $1:game_id::STRING              AS game_id,
        $1:game_date::DATE              AS game_date,
        $1:home_team_abbr::STRING       AS home_team_abbr,
        $1:home_q1::INT                 AS home_q1,
        $1:home_q2::INT                 AS home_q2,
        $1:home_q3::INT                 AS home_q3,
        $1:home_q4::INT                 AS home_q4,
        $1:home_ot1::INT                AS home_ot1,
        $1:home_ot2::INT                AS home_ot2,
        $1:home_ot3::INT                AS home_ot3,
        $1:home_ot4::INT                AS home_ot4,
        $1:home_pts::INT                AS home_pts,
        $1:away_team_abbr::STRING       AS away_team_abbr,
        $1:away_q1::INT                 AS away_q1,
        $1:away_q2::INT                 AS away_q2,
        $1:away_q3::INT                 AS away_q3,
        $1:away_q4::INT                 AS away_q4,
        $1:away_ot1::INT                AS away_ot1,
        $1:away_ot2::INT                AS away_ot2,
        $1:away_ot3::INT                AS away_ot3,
        $1:away_ot4::INT                AS away_ot4,
        $1:away_pts::INT                AS away_pts,
        $1:source::STRING               AS source,
        $1:fetched_at::TIMESTAMP_NTZ    AS fetched_at
    FROM {stage_file}
    (FILE_FORMAT => 'ZK_NBA.RAW.JSON_FF')
) AS src
ON target.game_id = src.game_id
WHEN MATCHED THEN UPDATE SET
    game_date = src.game_date,
    home_team_abbr = src.home_team_abbr,
    home_q1 = src.home_q1, home_q2 = src.home_q2, home_q3 = src.home_q3, home_q4 = src.home_q4,
    home_ot1 = src.home_ot1, home_ot2 = src.home_ot2, home_ot3 = src.home_ot3, home_ot4 = src.home_ot4,
    home_pts = src.home_pts,
    away_team_abbr = src.away_team_abbr,
    away_q1 = src.away_q1, away_q2 = src.away_q2, away_q3 = src.away_q3, away_q4 = src.away_q4,
    away_ot1 = src.away_ot1, away_ot2 = src.away_ot2, away_ot3 = src.away_ot3, away_ot4 = src.away_ot4,
    away_pts = src.away_pts,
    source = src.source,
    fetched_at = src.fetched_at
WHEN NOT MATCHED THEN INSERT (
    game_id, game_date, home_team_abbr,
    home_q1, home_q2, home_q3, home_q4,
    home_ot1, home_ot2, home_ot3, home_ot4, home_pts,
    away_team_abbr,
    away_q1, away_q2, away_q3, away_q4,
    away_ot1, away_ot2, away_ot3, away_ot4, away_pts,
    source, fetched_at
) VALUES (
    src.game_id, src.game_date, src.home_team_abbr,
    src.home_q1, src.home_q2, src.home_q3, src.home_q4,
    src.home_ot1, src.home_ot2, src.home_ot3, src.home_ot4, src.home_pts,
    src.away_team_abbr,
    src.away_q1, src.away_q2, src.away_q3, src.away_q4,
    src.away_ot1, src.away_ot2, src.away_ot3, src.away_ot4, src.away_pts,
    src.source, src.fetched_at
)
"""


def _write_ndjson(records: list[dict], path: Path) -> None:
    with path.open("w") as f:
        for record in records:
            f.write(json.dumps(record, default=str) + "\n")


def _merge_rows(
    conn,
    rows: list[dict],
    merge_sql_template: str,
    file_label: str,
    slug: str,
    tmpdir: Path,
) -> tuple[int, int]:
    """PUT NDJSON of `rows` to the stage and run the MERGE.

    Returns (inserted_count, updated_count) extracted from MERGE result.
    """
    if not rows:
        return (0, 0)
    tmp_path = tmpdir / f"{file_label}_{slug}.ndjson"
    _write_ndjson(rows, tmp_path)
    merge_sql = merge_sql_template.replace("{stage_file}", f"{STAGE_PATH}/{tmp_path.name}")
    result = snowflake_client.put_and_merge(conn, tmp_path, STAGE_PATH, merge_sql)
    # MERGE returns one row per execution: (inserted_count, updated_count)
    merge_rows = result["merge"]
    if merge_rows and len(merge_rows[0]) >= 2:
        inserted, updated = merge_rows[0][0], merge_rows[0][1]
    else:
        inserted, updated = 0, 0
    logger.info("[%s] MERGE: %d inserted, %d updated", file_label, inserted, updated)
    return inserted, updated


def _settle_game(slug: str, conn, tmpdir: Path) -> dict:
    """Settle a single game; shares an open conn + tmpdir with the caller.

    Used by both settle_one() (single-game CLI) and settle_date() (daily loop).
    Lifting connection ownership to the caller avoids re-connecting per game
    when a daily run has ~14 games.

    Returns a dict summarizing the row counts and (inserted, updated) per
    table. On per-game failure, raises — the caller decides whether to halt
    or continue.
    """
    logger.info("Settling %s", slug)
    box = fetch_boxscore(slug)

    home_team = box["home_team"]
    away_team = box["away_team"]
    if not home_team or not away_team:
        raise RuntimeError(f"Could not determine teams for {slug}")

    home_df = box["basic"].get("home")
    away_df = box["basic"].get("away")
    if home_df is None or away_df is None:
        raise RuntimeError(f"Missing basic box DataFrame(s) for {slug}")

    game_row = flatten_game_row(
        game_slug=slug,
        home_team=home_team,
        away_team=away_team,
        home_basic_df=home_df,
        away_basic_df=away_df,
        line_score_df=box.get("line_score"),
    )
    if game_row is None:
        raise RuntimeError(f"flatten_game_row returned None for {slug}")

    # Decision #3: resolve every BR player slug to canonical NBA Stats API id.
    # This is the single source of truth for player_id across all FLAT tables.
    # The resolver checks DERIVED.player_xref first (instant); only never-seen
    # slugs require a one-time BR player-page fetch.
    player_anchors = box.get("player_anchors", {})
    slug_to_nba = resolve_player_ids(conn, player_anchors)

    player_rows = (
        flatten_player_box_basic(slug, home_team, home_df, is_home=True,
                                 player_anchors=player_anchors, slug_to_nba=slug_to_nba)
        + flatten_player_box_basic(slug, away_team, away_df, is_home=False,
                                   player_anchors=player_anchors, slug_to_nba=slug_to_nba)
    )
    advanced_rows = (
        flatten_player_box_advanced(slug, home_team, box["advanced"].get("home"),
                                    player_anchors=player_anchors, slug_to_nba=slug_to_nba)
        + flatten_player_box_advanced(slug, away_team, box["advanced"].get("away"),
                                      player_anchors=player_anchors, slug_to_nba=slug_to_nba)
    )
    line_row = flatten_line_score(slug, box.get("line_score"))
    line_rows = [line_row] if line_row else []

    g_ins, g_upd = _merge_rows(conn, [game_row], GAMES_MERGE_SQL, "games", slug, tmpdir)
    b_ins, b_upd = _merge_rows(conn, player_rows, PLAYER_BOX_BASIC_MERGE_SQL,
                                "player_box_basic", slug, tmpdir)
    a_ins, a_upd = _merge_rows(conn, advanced_rows, PLAYER_BOX_ADVANCED_MERGE_SQL,
                                "player_box_advanced", slug, tmpdir)
    l_ins, l_upd = _merge_rows(conn, line_rows, LINE_SCORES_MERGE_SQL,
                                "line_scores", slug, tmpdir)

    return {
        "game_id": slug,
        "game_row": game_row,
        "player_count": len(player_rows),
        "advanced_count": len(advanced_rows),
        "line_score_count": len(line_rows),
        "games_inserted": g_ins, "games_updated": g_upd,
        "player_box_inserted": b_ins, "player_box_updated": b_upd,
        "player_box_advanced_inserted": a_ins, "player_box_advanced_updated": a_upd,
        "line_scores_inserted": l_ins, "line_scores_updated": l_upd,
    }


def settle_one(slug: str) -> dict:
    """Settle a single game by slug (CLI entry point).

    Thin wrapper around _settle_game that opens its own conn + tmpdir.
    """
    conn = snowflake_client.connect()
    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            return _settle_game(slug, conn, Path(tmpdir))
    finally:
        conn.close()


def settle_date(target_date: date) -> dict:
    """Settle all games on the given date (Slice G daily loop).

    Iterates list_games_on_date(target_date) and calls _settle_game for each
    slug, sharing one Snowflake connection across all games. Per-game failures
    log + continue; only one game's miss doesn't halt the rest.

    Returns aggregate counters across all games settled.
    """
    slugs = list_games_on_date(target_date)
    logger.info("settle_date(%s) — found %d game(s)", target_date, len(slugs))
    if not slugs:
        logger.info("No games on %s — exiting cleanly.", target_date)
        return {"date": target_date.isoformat(), "games_found": 0, "games_settled": 0,
                "games_failed": 0, "totals": {}}

    totals = {"games_inserted": 0, "games_updated": 0,
              "player_box_inserted": 0, "player_box_updated": 0,
              "player_box_advanced_inserted": 0, "player_box_advanced_updated": 0,
              "line_scores_inserted": 0, "line_scores_updated": 0,
              "player_count": 0, "advanced_count": 0}
    settled = 0
    failed: list[tuple[str, str]] = []

    conn = snowflake_client.connect()
    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            for i, slug in enumerate(slugs, 1):
                logger.info("--- [%d/%d] %s ---", i, len(slugs), slug)
                try:
                    result = _settle_game(slug, conn, tmp)
                    for k in totals:
                        totals[k] += result.get(k, 0)
                    settled += 1
                except Exception as e:
                    logger.error("Settle failed for %s: %s", slug, e)
                    failed.append((slug, str(e)))
    finally:
        conn.close()

    logger.info(
        "settle_date(%s) complete: %d/%d games settled "
        "(games +%d/~%d, basic +%d/~%d, advanced +%d/~%d, line +%d/~%d)",
        target_date, settled, len(slugs),
        totals["games_inserted"], totals["games_updated"],
        totals["player_box_inserted"], totals["player_box_updated"],
        totals["player_box_advanced_inserted"], totals["player_box_advanced_updated"],
        totals["line_scores_inserted"], totals["line_scores_updated"],
    )
    if failed:
        logger.warning("Failed slugs (%d): %s", len(failed), [s for s, _ in failed])
    return {"date": target_date.isoformat(), "games_found": len(slugs),
            "games_settled": settled, "games_failed": len(failed), "totals": totals}


def main() -> None:
    """CLI dispatcher.

    Mode selection:
        SETTLE_SLUG=20240409xxx  -> settle just this slug (debug)
        SETTLE_DATE=YYYY-MM-DD   -> settle all games on this date
        (neither set)            -> settle all games from yesterday (cron mode)
    """
    slug_env = os.environ.get("SETTLE_SLUG", "").strip()
    date_env = os.environ.get("SETTLE_DATE", "").strip()

    if slug_env:
        logger.info("settle_one mode (SETTLE_SLUG=%s)", slug_env)
        settle_one(slug_env)
        return

    if date_env:
        target_date = datetime.strptime(date_env, "%Y-%m-%d").date()
    else:
        target_date = date.today() - timedelta(days=1)

    logger.info("settle_date mode (target_date=%s)", target_date)
    settle_date(target_date)


if __name__ == "__main__":
    main()
