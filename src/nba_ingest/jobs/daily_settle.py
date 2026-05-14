"""Daily settle job: ingest all games from the previous calendar day.

Triggered by GitHub Actions cron (8:30 UTC = ~3:30am ET — all games are final
by then including late West Coast games).

Supports manual override via SETTLE_DATE env var for backfill or debugging:
    SETTLE_DATE=2024-01-15 python -m nba_ingest.jobs.daily_settle

Exits cleanly with code 0 if there are no games on the target date (off-day,
off-season). No Snowflake writes happen in that case.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import tempfile
from datetime import date, datetime, timedelta
from pathlib import Path

from nba_ingest import snowflake_client
from nba_ingest.fetchers.boxscore import fetch_boxscore
from nba_ingest.fetchers.games import list_games_on_date
from nba_ingest.flatteners.boxscore import (
    flatten_game_meta,
    flatten_line_score,
    flatten_player_box_advanced,
    flatten_player_box_basic,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)


def _settle_date() -> date:
    """Return the date to settle. Env var overrides yesterday."""
    env_date = os.environ.get("SETTLE_DATE", "").strip()
    if env_date:
        return datetime.strptime(env_date, "%Y-%m-%d").date()
    return date.today() - timedelta(days=1)


def _write_ndjson(records: list[dict], path: Path) -> None:
    """Write a list of dicts to an NDJSON file."""
    with path.open("w") as f:
        for record in records:
            # datetime objects aren't JSON-serializable by default.
            f.write(json.dumps(record, default=str) + "\n")


def _merge_player_box_basic(conn, ndjson_path: Path, stage: str) -> None:
    """PUT + MERGE player_box_basic rows from an NDJSON file."""
    merge_sql = f"""
    MERGE INTO ZK_NBA.FLAT.player_box_basic AS target
    USING (
        SELECT
            $1:game_id::STRING         AS game_id,
            $1:player_id::STRING       AS player_id,
            $1:player_name::STRING     AS player_name,
            $1:team_abbr::STRING       AS team_abbr,
            $1:game_date::DATE         AS game_date,
            $1:is_home::BOOLEAN        AS is_home,
            $1:minutes_played::FLOAT   AS minutes_played,
            $1:pts::INT                AS pts,
            $1:ast::INT                AS ast,
            $1:reb::INT                AS reb,
            $1:oreb::INT               AS oreb,
            $1:dreb::INT               AS dreb,
            $1:stl::INT                AS stl,
            $1:blk::INT                AS blk,
            $1:tov::INT                AS tov,
            $1:pf::INT                 AS pf,
            $1:fgm::INT                AS fgm,
            $1:fga::INT                AS fga,
            $1:fg_pct::FLOAT           AS fg_pct,
            $1:fg3m::INT               AS fg3m,
            $1:fg3a::INT               AS fg3a,
            $1:fg3_pct::FLOAT          AS fg3_pct,
            $1:ftm::INT                AS ftm,
            $1:fta::INT                AS fta,
            $1:ft_pct::FLOAT           AS ft_pct,
            $1:plus_minus::FLOAT       AS plus_minus,
            $1:source::STRING          AS source,
            $1:fetched_at::TIMESTAMP_NTZ AS fetched_at
        FROM {stage}/{ndjson_path.name}
        (FILE_FORMAT => (TYPE = 'JSON'))
    ) AS src
    ON target.game_id = src.game_id AND target.player_name = src.player_name
    WHEN MATCHED THEN UPDATE SET
        player_name = src.player_name,
        team_abbr = src.team_abbr,
        minutes_played = src.minutes_played,
        pts = src.pts,
        ast = src.ast,
        reb = src.reb,
        fetched_at = src.fetched_at
    WHEN NOT MATCHED THEN INSERT (
        game_id, player_id, player_name, team_abbr, game_date, is_home,
        minutes_played, pts, ast, reb, oreb, dreb, stl, blk, tov, pf,
        fgm, fga, fg_pct, fg3m, fg3a, fg3_pct, ftm, fta, ft_pct,
        plus_minus, source, fetched_at
    ) VALUES (
        src.game_id, src.player_id, src.player_name, src.team_abbr, src.game_date, src.is_home,
        src.minutes_played, src.pts, src.ast, src.reb, src.oreb, src.dreb, src.stl, src.blk,
        src.tov, src.pf, src.fgm, src.fga, src.fg_pct, src.fg3m, src.fg3a, src.fg3_pct,
        src.ftm, src.fta, src.ft_pct, src.plus_minus, src.source, src.fetched_at
    )
    """
    snowflake_client.put_and_merge(conn, ndjson_path, stage, merge_sql)


def main() -> None:
    target_date = _settle_date()
    logger.info("Settling games for %s", target_date)

    slugs = list_games_on_date(target_date)

    if not slugs:
        logger.info("No games on %s — exiting cleanly.", target_date)
        sys.exit(0)

    logger.info("Settling %d game(s) for %s: %s", len(slugs), target_date, slugs)

    all_basic: list[dict] = []
    all_advanced: list[dict] = []
    all_line_scores: list[dict] = []

    for slug in slugs:
        logger.info("Processing %s", slug)
        try:
            box = fetch_boxscore(slug)
        except Exception as e:
            logger.error("Failed to fetch boxscore for %s: %s", slug, e)
            continue

        home_team = box["home_team"]
        away_team = box["away_team"]

        # Basic box scores (home + away).
        for team, is_home in ((home_team, True), (away_team, False)):
            if not team:
                continue
            df = box["basic"].get("home" if is_home else "away")
            if df is not None:
                all_basic.extend(flatten_player_box_basic(slug, team, df, is_home))

        # Advanced box scores (home + away).
        for team, key in ((home_team, "home"), (away_team, "away")):
            if not team:
                continue
            df = box["advanced"].get(key)
            if df is not None:
                all_advanced.extend(flatten_player_box_advanced(slug, team, df))

        # Line score.
        if box["line_score"] is not None:
            ls = flatten_line_score(slug, box["line_score"])
            if ls:
                all_line_scores.append(ls)

    logger.info(
        "Flattened: %d player-game basic rows, %d advanced rows, %d line scores",
        len(all_basic),
        len(all_advanced),
        len(all_line_scores),
    )

    # NOTE: Stage path below assumes an internal stage exists.
    # For a simple setup without a dedicated stage, use direct INSERT via
    # snowflake_client.execute() with a VALUES clause for small daily volumes.
    # Full PUT+MERGE implementation requires creating the stage first.
    # TODO: Create ZK_NBA.RAW.INGEST_STAGE in a future sql/010_stage.sql file.
    stage = "@ZK_NBA.RAW.INGEST_STAGE/flat"

    conn = snowflake_client.connect()
    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)

            if all_basic:
                basic_file = tmp / f"player_box_basic_{target_date}.ndjson"
                _write_ndjson(all_basic, basic_file)
                _merge_player_box_basic(conn, basic_file, stage)
                logger.info("Merged %d player_box_basic rows", len(all_basic))

            # TODO: add merge for player_box_advanced and line_scores (same pattern)

    finally:
        conn.close()

    logger.info("Settle complete for %s", target_date)


if __name__ == "__main__":
    main()
