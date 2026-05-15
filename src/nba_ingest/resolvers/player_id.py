"""Resolve BR player slugs to canonical NBA Stats API IDs.

Architecture (Decision #3):
    Every BR-scraped player_box row stores player_id = NBA Stats API ID (e.g.,
    "1641705"), not the BR slug. The resolver discovers the mapping via three
    tiers, persisting all resolutions in DERIVED.player_xref so the second
    encounter of a slug is O(1).

Resolution tiers (priority order):

    1. Lookup by br_slug in DERIVED.player_xref.
       Hits when we've resolved this slug before (cache hit).

    2. Lookup by player_name in DERIVED.player_xref.
       Hits for any player JB seed knew. We then UPDATE the row to set
       br_slug, so the next encounter is a tier-1 hit.

    3. Fetch the BR player page, extract NBA ID from `stats.nba.com/player/`
       external link, INSERT a new xref row.
       Hits for post-Apr-2025 rookies and any player JB didn't have. One BR
       page fetch per never-seen-before slug — amortized across all future
       encounters of that player.

The pre-2003 retired-players gap (Wilt, Russell, etc. — no NBA.com link on
their BR page) is irrelevant in practice: those players don't appear in BR
scrapes because they're retired. Tier 3 is only invoked for players in a
current/recent BR boxscore who weren't in JB seed — all of whom are
recently active and have NBA.com profiles.

Defensive fallback: if tier 3 fetch finds no NBA id (would only happen for
hypothetical impossible cases like a deactivated NBA.com profile), the
function returns the BR slug as a last-resort `player_id`. Documented but
not expected to fire.
"""

from __future__ import annotations

import logging
import re
from typing import Optional

from nba_ingest.br_client import BASE_URL, fetch

logger = logging.getLogger(__name__)


NBA_ID_PATTERN = re.compile(r"stats\.nba\.com/player/(\d+)")


def _extract_nba_id_from_player_page(br_slug: str) -> Optional[str]:
    """Fetch BR player page and extract NBA Stats API id from external link.

    Returns the NBA id string (e.g., "1641705") or None if the page has no
    stats.nba.com link (very rare; pre-NBA.com-era retired players).
    """
    if not br_slug or len(br_slug) < 2:
        return None
    url = f"{BASE_URL}/players/{br_slug[0]}/{br_slug}.html"
    try:
        html = fetch(url)
    except Exception as e:
        logger.warning("Could not fetch BR player page %s: %s", br_slug, e)
        return None
    matches = NBA_ID_PATTERN.findall(html)
    if not matches:
        logger.warning("No stats.nba.com link on BR page for %s", br_slug)
        return None
    nba_id = matches[0]  # all hits on the page should reference the same id
    return nba_id


def resolve_player_ids(conn, anchors: dict[str, str]) -> dict[str, str]:
    """Resolve a batch of BR player slugs to NBA Stats API IDs.

    Args:
        conn: Open Snowflake connection (used for xref reads + writes).
        anchors: dict of {player_name: br_slug} extracted from boxscore HTML.

    Returns:
        dict of {br_slug: nba_id}. Every input slug appears in the output. If
        a slug failed both name lookup and BR fetch, its output value is the
        slug itself (last-resort fallback).
    """
    if not anchors:
        return {}

    slug_to_nba: dict[str, str] = {}
    slugs_needing_fetch: list[tuple[str, str]] = []  # (slug, name)

    cur = conn.cursor()
    try:
        # Tier 1: bulk lookup by slug — get all entries where br_slug matches
        slugs = list({s for s in anchors.values() if s})
        if slugs:
            placeholders = ",".join(["%s"] * len(slugs))
            cur.execute(
                f"SELECT br_slug, nba_id FROM ZK_NBA.DERIVED.player_xref "
                f"WHERE br_slug IN ({placeholders})",
                slugs,
            )
            for br_slug, nba_id in cur.fetchall():
                slug_to_nba[br_slug] = nba_id

        # Tier 2: for slugs not in tier 1, try name lookup
        for name, slug in anchors.items():
            if slug in slug_to_nba:
                continue
            cur.execute(
                "SELECT nba_id FROM ZK_NBA.DERIVED.player_xref "
                "WHERE player_name = %s AND br_slug IS NULL LIMIT 1",
                (name,),
            )
            row = cur.fetchone()
            if row:
                nba_id = row[0]
                slug_to_nba[slug] = nba_id
                # Backfill the slug onto this row so tier 1 hits next time
                cur.execute(
                    "UPDATE ZK_NBA.DERIVED.player_xref "
                    "SET br_slug = %s, fetched_at = CURRENT_TIMESTAMP() "
                    "WHERE nba_id = %s AND br_slug IS NULL",
                    (slug, nba_id),
                )
                logger.info("xref: tier-2 name match for %s → %s (br_slug backfilled)",
                            name, nba_id)
            else:
                slugs_needing_fetch.append((slug, name))

        # Tier 3: for remaining slugs, fetch BR player page
        for slug, name in slugs_needing_fetch:
            nba_id = _extract_nba_id_from_player_page(slug)
            if nba_id:
                slug_to_nba[slug] = nba_id
                # Insert new xref row
                cur.execute(
                    "INSERT INTO ZK_NBA.DERIVED.player_xref "
                    "(nba_id, br_slug, player_name, source, fetched_at) "
                    "VALUES (%s, %s, %s, 'br_resolve', CURRENT_TIMESTAMP())",
                    (nba_id, slug, name),
                )
                logger.info("xref: tier-3 BR fetch resolved %s (%s) → %s",
                            slug, name, nba_id)
            else:
                # Defensive fallback: slug as the id.
                slug_to_nba[slug] = slug
                logger.warning("xref: ALL TIERS FAILED for slug=%s name=%s; using slug as player_id",
                               slug, name)
    finally:
        cur.close()

    return slug_to_nba
