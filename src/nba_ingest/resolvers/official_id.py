"""Resolve BR referee slugs to canonical NBA Stats API official IDs.

Architecture mirrors player_id resolver but with one key difference: BR's
referee pages do NOT contain stats.nba.com external links (verified
empirically — NBA.com has an /officials directory but doesn't publish
per-ref ID URLs). So there is no tier-3 BR-fetch fallback for officials.

Resolution tiers:

    1. Lookup by br_slug in DERIVED.official_xref.
    2. Lookup by name (first + last) in xref.
       UPDATE backfills br_slug so tier-1 hits next time.
    3. *no tier-3* — defensive fallback uses BR slug as the official_id.

The JB seed populated DERIVED.official_xref with 235 entries covering every
official who appeared in a pre-Jun-2023 NBA game. New refs added since
then will fall back to the BR slug as their canonical id. This affects a
small number of refs per season (typically 2-5 new refs hired).
"""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def resolve_official_ids(conn, officials: list[dict]) -> dict[str, str]:
    """Resolve a list of officials (with names + slugs) to NBA official IDs.

    Args:
        conn: Open Snowflake connection.
        officials: List of dicts, each with keys 'name' (str) and 'br_slug' (str).

    Returns:
        dict of {br_slug: nba_id}. Defensive fallback: if name lookup fails,
        the slug is used as its own id.
    """
    if not officials:
        return {}

    slug_to_nba: dict[str, str] = {}

    cur = conn.cursor()
    try:
        # Tier 1: bulk by slug
        slugs = [o["br_slug"] for o in officials if o.get("br_slug")]
        if slugs:
            placeholders = ",".join(["%s"] * len(slugs))
            cur.execute(
                f"SELECT br_slug, nba_id FROM ZK_NBA.DERIVED.official_xref "
                f"WHERE br_slug IN ({placeholders})",
                slugs,
            )
            for br_slug, nba_id in cur.fetchall():
                slug_to_nba[br_slug] = nba_id

        # Tier 2: by name. JB seed stores first_name and last_name separately;
        # BR meta gives us a single "Curtis Blair" string. Split on whitespace
        # and try first_name='Curtis' last_name='Blair'.
        for o in officials:
            slug = o.get("br_slug")
            name = o.get("name", "").strip()
            if not slug or slug in slug_to_nba or not name:
                continue
            parts = name.split(None, 1)
            if len(parts) != 2:
                continue
            first, last = parts
            cur.execute(
                "SELECT nba_id FROM ZK_NBA.DERIVED.official_xref "
                "WHERE first_name = %s AND last_name = %s AND br_slug IS NULL LIMIT 1",
                (first, last),
            )
            row = cur.fetchone()
            if row:
                nba_id = row[0]
                slug_to_nba[slug] = nba_id
                cur.execute(
                    "UPDATE ZK_NBA.DERIVED.official_xref "
                    "SET br_slug = %s, fetched_at = CURRENT_TIMESTAMP() "
                    "WHERE nba_id = %s AND br_slug IS NULL",
                    (slug, nba_id),
                )
                logger.info("official_xref: tier-2 name match for %s → %s (br_slug backfilled)",
                            name, nba_id)
            else:
                # Defensive fallback: slug as the id, and persist the new entry
                # so future encounters skip the failed lookup.
                slug_to_nba[slug] = slug
                cur.execute(
                    "INSERT INTO ZK_NBA.DERIVED.official_xref "
                    "(nba_id, br_slug, first_name, last_name, source, fetched_at) "
                    "VALUES (%s, %s, %s, %s, 'br_fallback', CURRENT_TIMESTAMP())",
                    (slug, slug, first, last),
                )
                logger.warning("official_xref: name match failed for %s (slug %s); "
                               "using slug as official_id", name, slug)
    finally:
        cur.close()

    return slug_to_nba
