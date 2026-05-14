"""Weekly metadata refresh job.

Refreshes slowly-changing tables that aren't worth touching daily:
  - FLAT.draft_career_stats: career stats for recent draft classes (live BR data)
  - FLAT.teams: arena, coach, capacity (still TODO — needs new fetcher)
  - FLAT.draft: add 2024/2025 draft classes (still TODO — needs new flattener)

Modes (selected by env var):

    WEEKLY_META_YEARS=2020,2021,2022,2023,2024,2025
        Run refresh_draft_career_stats over these draft years. Default if
        no env var is set: last 6 years (2020-2025).

Run:
    python -m nba_ingest.jobs.weekly_meta
"""

from __future__ import annotations

import json
import logging
import os
import tempfile
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[3] / ".env", override=False)

from nba_ingest import snowflake_client
from nba_ingest.fetchers.draft import fetch_draft_class
from nba_ingest.flatteners.draft import flatten_draft_career_stats

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)


STAGE_PATH = "@ZK_NBA.RAW.INGEST_STAGE/flat"

DEFAULT_YEARS = list(range(2020, datetime.now().year + 1))


DRAFT_CAREER_STATS_MERGE_SQL = """
MERGE INTO ZK_NBA.FLAT.draft_career_stats AS target
USING (
    SELECT
        $1:season::INT                  AS season,
        $1:overall_pick::INT            AS overall_pick,
        $1:player_name::STRING          AS player_name,
        $1:team_abbr::STRING            AS team_abbr,
        $1:college::STRING              AS college,
        $1:career_games::INT            AS career_games,
        $1:career_pts_per_game::FLOAT   AS career_pts_per_game,
        $1:career_reb_per_game::FLOAT   AS career_reb_per_game,
        $1:career_ast_per_game::FLOAT   AS career_ast_per_game,
        $1:career_fg_pct::FLOAT         AS career_fg_pct,
        $1:career_fg3_pct::FLOAT        AS career_fg3_pct,
        $1:career_ft_pct::FLOAT         AS career_ft_pct,
        $1:career_win_shares::FLOAT     AS career_win_shares,
        $1:career_ws_per_48::FLOAT      AS career_ws_per_48,
        $1:career_bpm::FLOAT            AS career_bpm,
        $1:career_vorp::FLOAT           AS career_vorp,
        $1:fetched_at::TIMESTAMP_NTZ    AS fetched_at
    FROM {stage_file}
    (FILE_FORMAT => 'ZK_NBA.RAW.JSON_FF')
) AS src
ON target.season = src.season AND target.overall_pick = src.overall_pick
WHEN MATCHED THEN UPDATE SET
    player_name = src.player_name, team_abbr = src.team_abbr, college = src.college,
    career_games = src.career_games,
    career_pts_per_game = src.career_pts_per_game,
    career_reb_per_game = src.career_reb_per_game,
    career_ast_per_game = src.career_ast_per_game,
    career_fg_pct = src.career_fg_pct, career_fg3_pct = src.career_fg3_pct,
    career_ft_pct = src.career_ft_pct,
    career_win_shares = src.career_win_shares,
    career_ws_per_48 = src.career_ws_per_48,
    career_bpm = src.career_bpm, career_vorp = src.career_vorp,
    fetched_at = src.fetched_at
WHEN NOT MATCHED THEN INSERT (
    season, overall_pick, player_name, team_abbr, college,
    career_games, career_pts_per_game, career_reb_per_game, career_ast_per_game,
    career_fg_pct, career_fg3_pct, career_ft_pct,
    career_win_shares, career_ws_per_48, career_bpm, career_vorp,
    fetched_at
) VALUES (
    src.season, src.overall_pick, src.player_name, src.team_abbr, src.college,
    src.career_games, src.career_pts_per_game, src.career_reb_per_game, src.career_ast_per_game,
    src.career_fg_pct, src.career_fg3_pct, src.career_ft_pct,
    src.career_win_shares, src.career_ws_per_48, src.career_bpm, src.career_vorp,
    src.fetched_at
)
"""


def _write_ndjson(records: list[dict], path: Path) -> None:
    with path.open("w") as f:
        for record in records:
            f.write(json.dumps(record, default=str) + "\n")


def _merge_rows(conn, rows: list[dict], merge_sql_template: str,
                file_label: str, tmpdir: Path) -> tuple[int, int]:
    """PUT NDJSON and MERGE. Returns (inserted_count, updated_count)."""
    if not rows:
        return (0, 0)
    tmp_path = tmpdir / f"{file_label}.ndjson"
    _write_ndjson(rows, tmp_path)
    merge_sql = merge_sql_template.replace("{stage_file}", f"{STAGE_PATH}/{tmp_path.name}")
    result = snowflake_client.put_and_merge(conn, tmp_path, STAGE_PATH, merge_sql)
    merge_rows = result["merge"]
    if merge_rows and len(merge_rows[0]) >= 2:
        inserted, updated = merge_rows[0][0], merge_rows[0][1]
    else:
        inserted, updated = 0, 0
    logger.info("[%s] MERGE: %d inserted, %d updated", file_label, inserted, updated)
    return inserted, updated


def refresh_draft_career_stats(years: list[int]) -> dict:
    """Pull BR draft class pages for each year, MERGE career stats into FLAT.

    Career stats on BR draft pages update in real-time as players play, so
    rerunning weekly keeps draft_career_stats current.
    """
    all_rows: list[dict] = []
    for year in years:
        logger.info("Fetching draft class %d", year)
        df = fetch_draft_class(year)
        if df is None:
            logger.warning("No draft class data for %d", year)
            continue
        rows = flatten_draft_career_stats(year, df)
        logger.info("Flattened %d picks for %d", len(rows), year)
        all_rows.extend(rows)

    logger.info("Total picks across all years: %d", len(all_rows))

    conn = snowflake_client.connect()
    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            inserted, updated = _merge_rows(
                conn, all_rows, DRAFT_CAREER_STATS_MERGE_SQL,
                f"draft_career_stats_{years[0]}_{years[-1]}", Path(tmpdir),
            )
    finally:
        conn.close()

    return {
        "years": years, "rows_seen": len(all_rows),
        "inserted": inserted, "updated": updated,
    }


def refresh_teams() -> None:
    """Refresh FLAT.teams from BR team pages.

    TODO (deferred): requires a new fetcher for BR team season pages
    (https://www.basketball-reference.com/teams/{TEAM}/{YEAR}.html) and a
    flattener for arena / capacity / head_coach extraction from the page's
    summary panel. Goal: fill arena/coach for the 5 teams missing from JB
    (ORL, NYK, BOS, CLE, NOP).
    """
    logger.info("refresh_teams — TODO (needs new BR team-page fetcher + flattener)")


def refresh_draft_classes() -> None:
    """Add 2024 and 2025 draft classes to FLAT.draft.

    TODO (deferred): the existing flatten_draft_career_stats writes to
    FLAT.draft_career_stats (live stats), not FLAT.draft (pick-record table).
    Need a new flatten_draft_picks that extracts: person_id, player_name,
    season, round_number, round_pick, overall_pick, draft_type, team_id,
    team_abbr, organization, organization_type — these columns ARE on BR's
    draft class pages but require a different mapping than career stats.
    """
    logger.info("refresh_draft_classes — TODO (needs flatten_draft_picks)")


def main() -> None:
    years_env = os.environ.get("WEEKLY_META_YEARS", "").strip()
    if years_env:
        years = [int(y.strip()) for y in years_env.split(",") if y.strip()]
    else:
        years = DEFAULT_YEARS

    logger.info("Weekly meta refresh — years: %s", years)
    result = refresh_draft_career_stats(years)
    logger.info(
        "Done: %d rows across %d years (+%d inserted, ~%d updated)",
        result["rows_seen"], len(result["years"]),
        result["inserted"], result["updated"],
    )

    # Stubs still — left as documented TODOs:
    refresh_teams()
    refresh_draft_classes()


if __name__ == "__main__":
    main()
