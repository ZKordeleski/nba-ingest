"""Slice A: settle one game into FLAT.games.

This is the minimal end-to-end pipeline: fetch a BR boxscore by slug, flatten
to a single FLAT.games row, MERGE into Snowflake. It proves the game→Snowflake
pipe before later slices add player_box, line_scores, etc.

Usage:
    # Slice A test (default known-good slug):
    python -m nba_ingest.jobs.daily_settle

    # Specify a different slug:
    SETTLE_SLUG=20240409OMEM python -m nba_ingest.jobs.daily_settle

The MERGE is idempotent on game_id. Re-running on the same slug updates the
existing row in place (fetched_at advances, stat columns reflect the latest
fetch) — no duplicate row, no second insert.

Future slices (B-F) will extend this to player_box_basic, line_scores,
player_box_advanced, game_officials, game_inactives. Slice G adds the
multi-game daily loop. Until those slices land, this file does ONE thing well.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import tempfile
from pathlib import Path

from dotenv import load_dotenv

# Load .env for local CLI runs. override=False keeps CI-injected env vars
# (e.g. from GitHub Actions secrets) authoritative.
load_dotenv(Path(__file__).resolve().parents[3] / ".env", override=False)

from nba_ingest import snowflake_client
from nba_ingest.fetchers.boxscore import fetch_boxscore
from nba_ingest.flatteners.boxscore import (
    flatten_game_row,
    flatten_player_box_basic,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)

# Slice A test slug: 2024 Apr 9, SAS @ MEM, MEM 102-87. Known-good per HANDOFF.
# BR slug format: YYYYMMDD + "0" (digit separator) + HOME team (3 chars).
DEFAULT_SLUG = "202404090MEM"

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
-- MERGE key is (game_id, player_name). The PK is (game_id, player_id) but
-- BR scrapes leave player_id NULL until decision #3 (player_id from BR slug)
-- is implemented in a later slice. NULL = NULL is FALSE in SQL, so matching
-- on player_id alone would always insert new rows.
ON target.game_id = src.game_id AND target.player_name = src.player_name
WHEN MATCHED THEN UPDATE SET
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
    game_id, player_id, player_name, team_id, team_name, team_abbr,
    opponent_team_name, game_date, season, game_type, is_win, is_home,
    minutes_played, pts, ast, reb, oreb, dreb, stl, blk, tov, pf,
    fgm, fga, fg_pct, fg3m, fg3a, fg3_pct, ftm, fta, ft_pct,
    plus_minus, source, fetched_at
) VALUES (
    src.game_id, src.player_id, src.player_name, src.team_id, src.team_name, src.team_abbr,
    src.opponent_team_name, src.game_date, src.season, src.game_type, src.is_win, src.is_home,
    src.minutes_played, src.pts, src.ast, src.reb, src.oreb, src.dreb, src.stl, src.blk, src.tov, src.pf,
    src.fgm, src.fga, src.fg_pct, src.fg3m, src.fg3a, src.fg3_pct, src.ftm, src.fta, src.ft_pct,
    src.plus_minus, src.source, src.fetched_at
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


def settle_one(slug: str) -> dict:
    """Settle a single game by slug.

    Writes:
        - one FLAT.games row
        - N FLAT.player_box_basic rows (~20-30 per game)

    Returns a dict summarizing the work done.
    """
    logger.info("Fetching boxscore for %s", slug)
    box = fetch_boxscore(slug)

    home_team = box["home_team"]
    away_team = box["away_team"]
    if not home_team or not away_team:
        raise RuntimeError(f"Could not determine teams for {slug}")

    home_df = box["basic"].get("home")
    away_df = box["basic"].get("away")
    if home_df is None or away_df is None:
        raise RuntimeError(f"Missing basic box DataFrame(s) for {slug}")

    # Flatten: one games row + many player_box rows (home + away).
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

    player_rows = (
        flatten_player_box_basic(slug, home_team, home_df, is_home=True)
        + flatten_player_box_basic(slug, away_team, away_df, is_home=False)
    )

    logger.info(
        "Flattened: 1 game row (%s %s @ %s %s, %s) + %d player rows",
        away_team, game_row["away_pts"], home_team, game_row["home_pts"],
        game_row["game_date"], len(player_rows),
    )

    conn = snowflake_client.connect()
    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            games_inserted, games_updated = _merge_rows(
                conn, [game_row], GAMES_MERGE_SQL, "games", slug, tmp,
            )
            box_inserted, box_updated = _merge_rows(
                conn, player_rows, PLAYER_BOX_BASIC_MERGE_SQL,
                "player_box_basic", slug, tmp,
            )
    finally:
        conn.close()

    return {
        "game_id": slug,
        "game_row": game_row,
        "player_count": len(player_rows),
        "games_inserted": games_inserted,
        "games_updated": games_updated,
        "player_box_inserted": box_inserted,
        "player_box_updated": box_updated,
    }


def main() -> None:
    slug = os.environ.get("SETTLE_SLUG", "").strip() or DEFAULT_SLUG
    logger.info("Slice B — settling slug: %s", slug)
    result = settle_one(slug)
    logger.info(
        "Slice B done: game_id=%s, %s %s @ %s %s, %d player rows "
        "(games: +%d/~%d, player_box: +%d/~%d)",
        result["game_id"],
        result["game_row"]["away_team_abbr"], result["game_row"]["away_pts"],
        result["game_row"]["home_team_abbr"], result["game_row"]["home_pts"],
        result["player_count"],
        result["games_inserted"], result["games_updated"],
        result["player_box_inserted"], result["player_box_updated"],
    )


if __name__ == "__main__":
    main()
