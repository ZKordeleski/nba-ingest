"""Weekly metadata refresh job.

Scope: Slice 5. Refreshes slowly-changing metadata tables that aren't worth
updating daily:
  - FLAT.draft_career_stats: career stats for recent draft classes (BR draft pages)
  - FLAT.teams: arena, coach, capacity (may change mid-season)
  - FLAT.draft: add new draft classes (2024, 2025)

Currently contains logging stubs. Full implementation is Slice 5 scope.

Run:
    python -m nba_ingest.jobs.weekly_meta
"""

from __future__ import annotations

import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)


def refresh_draft_career_stats() -> None:
    """Refresh FLAT.draft_career_stats from BR draft class pages.

    Fetches career stats for recent draft classes (last 5 years).
    Uses fetch_draft_class() + flatten_draft_career_stats() + MERGE.
    """
    # TODO: implement in Slice 5
    logger.info("draft_career_stats refresh — not yet implemented (Slice 5)")


def refresh_teams() -> None:
    """Refresh FLAT.teams from BR team pages.

    Updates arena, capacity, head_coach fields which can change mid-season.
    Fills the 5 teams missing from JB seed (ORL, NYK, BOS, CLE, NOP).
    """
    # TODO: implement in Slice 5
    logger.info("teams refresh — not yet implemented (Slice 5)")


def refresh_draft_classes() -> None:
    """Add 2024 and 2025 draft classes to FLAT.draft.

    JB seed only has 1947-2023. BR has the full 2024 and 2025 classes.
    Uses fetch_draft_class() for each year and merges picks into FLAT.draft.
    """
    # TODO: implement in Slice 5
    logger.info("draft class refresh (2024, 2025) — not yet implemented (Slice 5)")


def main() -> None:
    logger.info("Starting weekly meta refresh")

    refresh_draft_career_stats()
    refresh_teams()
    refresh_draft_classes()

    logger.info("Weekly meta refresh complete (stubs only — implement in Slice 5)")


if __name__ == "__main__":
    main()
