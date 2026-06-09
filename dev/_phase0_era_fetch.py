"""Phase 0 era-sample fetch. Throwaway script — produces input to docs/BR_DATA_CATALOG.md."""

from __future__ import annotations

import re
import sys

sys.path.insert(0, "src")

from nba_ingest.br_client import (
    BASE_URL,
    extract_game_slugs_from_html,
    fetch,
    parse_tables_with_comments,
)

ERAS = [
    {"era": "1947", "date": (1946, 11, 1), "guess_slug": "194611010TRH", "label": "1946-11-01 NYK @ TOR (first BAA game)"},
    {"era": "1955", "date": (1955, 4, 10), "guess_slug": "195504100SYR", "label": "1955-04-10 Finals G7 FTW @ SYR"},
    {"era": "1965", "date": (1965, 4, 15), "guess_slug": "196504150BOS", "label": "1965-04-15 ECF G7 PHI @ BOS (Havlicek steal)"},
    {"era": "1975", "date": (1975, 5, 25), "guess_slug": "197505250WSB", "label": "1975-05-25 Finals G4 GSW @ WSB (sweep clinch)"},
    {"era": "1985", "date": (1985, 6, 9), "guess_slug": "198506090BOS", "label": "1985-06-09 Finals G6 LAL @ BOS (LAL clinch)"},
    {"era": "1995", "date": (1995, 6, 14), "guess_slug": "199506140ORL", "label": "1995-06-14 Finals G4 HOU @ ORL (sweep clinch)"},
    {"era": "2010", "date": (2010, 6, 17), "guess_slug": "201006170LAL", "label": "2010-06-17 Finals G7 BOS @ LAL"},
]

META_PATTERNS = {
    "attendance": r"<strong>Attendance:&nbsp;</strong>([^<]+)",
    "time_of_game": r"<strong>Time of Game:&nbsp;</strong>([^<]+)",
    "officials": r"<strong>Officials:&nbsp;</strong>(.*?)</div>",
    "inactives": r"<strong>Inactive:&nbsp;</strong>(.*?)</div>",
    "arena": r"<strong>Arena:&nbsp;</strong>([^<]+)",
    "tv": r"<strong>TV:&nbsp;</strong>([^<]+)",
    "series_h2": r"<h2>([^<]*Game\s*\d[^<]*)</h2>",
}


def resolve_slug(date: tuple[int, int, int], guess: str) -> tuple[str, str]:
    """Try the guessed slug; on 404 fall back to the daily index.

    Returns (slug, source) where source is 'guess' or 'index'.
    """
    y, m, d = date
    try:
        html = fetch(f"{BASE_URL}/boxscores/{guess}.html")
        # br_client.fetch raises on non-200, so reaching here means OK.
        return guess, "guess"
    except Exception as exc:  # noqa: BLE001 — broad catch is intentional for exploration
        print(f"  guess {guess!r} failed: {exc}; falling back to daily index")

    index_url = f"{BASE_URL}/boxscores/?month={m}&day={d}&year={y}"
    index_html = fetch(index_url)
    slugs = extract_game_slugs_from_html(index_html)
    if not slugs:
        raise RuntimeError(f"No slugs on index for {y}-{m:02d}-{d:02d}")
    return slugs[0], "index"


def summarize(slug: str, html: str) -> None:
    visible, hidden = parse_tables_with_comments(html)
    print(f"  HTML bytes: {len(html)}")
    print(f"  visible tables ({len(visible)}): {sorted(visible.keys())}")
    print(f"  hidden tables ({len(hidden)}): {sorted(hidden.keys())}")
    for key, pat in META_PATTERNS.items():
        m = re.search(pat, html, re.DOTALL)
        if m:
            value = m.group(1).strip()
            # Trim long officials/inactives lists for printability
            if len(value) > 180:
                value = value[:180] + "…"
            print(f"  meta.{key}: {value}")


def main() -> None:
    for entry in ERAS:
        print(f"\n=== {entry['era']} — {entry['label']} ===")
        slug, source = resolve_slug(entry["date"], entry["guess_slug"])
        print(f"  slug: {slug}  (resolved via {source})")
        url = f"{BASE_URL}/boxscores/{slug}.html"
        html = fetch(url)
        summarize(slug, html)


if __name__ == "__main__":
    main()
