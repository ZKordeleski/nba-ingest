"""Phase 0 closeout probe — READ-ONLY. No Snowflake, no writes.

Two investigations:
  (A) Where does BR encode the playoff round / series label ("NBA Finals",
      "Game 5")? Inspect a known Finals boxscore's header/meta + the bracket page.
  (B) Stat-category tracking boundaries: fetch one game per target season and
      print the basic-box column set, to confirm which stats BR exposes per era
      (steals/blocks 1973-74, turnovers 1977-78, 3P 1979-80).

Run: .venv/bin/python dev/_phase0_probe.py
"""

from __future__ import annotations

import re

from bs4 import BeautifulSoup

from nba_ingest.br_client import (
    BASE_URL,
    extract_game_slugs_from_html,
    fetch,
    parse_tables_with_comments,
)


def _flat_cols(df) -> list[str]:
    return [c[-1] if isinstance(c, tuple) else c for c in df.columns]


def first_slug_on(year: int, month: int, day: int) -> str | None:
    html = fetch(f"{BASE_URL}/boxscores/?month={month}&day={day}&year={year}")
    slugs = extract_game_slugs_from_html(html)
    return slugs[0] if slugs else None


def basic_box_columns(slug: str) -> dict[str, list[str]]:
    html = fetch(f"{BASE_URL}/boxscores/{slug}.html")
    visible, _hidden = parse_tables_with_comments(html)
    out: dict[str, list[str]] = {}
    for tid, df in visible.items():
        if tid.endswith("game-basic"):
            out[tid] = _flat_cols(df)
    return out


# ============================================================ (A) series label
print("=" * 70)
print("(A) SERIES LABEL / ROUND — 2023 Finals G5 (202306120DEN, DEN 94 MIA 89)")
print("=" * 70)
finals_slug = "202306120DEN"
html = fetch(f"{BASE_URL}/boxscores/{finals_slug}.html")
soup = BeautifulSoup(html, "html5lib")

title = soup.find("title")
print("title:", title.get_text(strip=True) if title else None)

for tag in ("h1", "h2"):
    for el in soup.find_all(tag)[:4]:
        print(f"<{tag}>:", el.get_text(" ", strip=True)[:160])

meta = soup.find("div", class_="scorebox_meta")
print("scorebox_meta:", meta.get_text(" | ", strip=True)[:400] if meta else None)

# Locate the tag context around the literal "Finals" / "Game 5" in raw HTML.
for kw in ("Finals", "Game 5", "Eastern Conference", "Western Conference"):
    idx = html.find(kw)
    if idx != -1:
        snippet = re.sub(r"\s+", " ", html[max(0, idx - 120):idx + 40])
        print(f"  ...context for {kw!r}: ...{snippet}...")
    else:
        print(f"  {kw!r}: NOT FOUND in raw HTML")

print()
print("--- playoff bracket page: /playoffs/NBA_2023.html ---")
bracket = fetch(f"{BASE_URL}/playoffs/NBA_2023.html")
bsoup = BeautifulSoup(bracket, "html5lib")
btitle = bsoup.find("title")
print("title:", btitle.get_text(strip=True) if btitle else None)
visible_b, _ = parse_tables_with_comments(bracket)
print("visible table ids:", sorted(visible_b.keys())[:25])
# Series rows usually appear as links to a series page; sample them.
series_links = sorted({m for m in re.findall(r"/playoffs/\d{4}-nba[^\"']+\.html", bracket)})[:12]
print("series-page links sampled:", series_links)
# Heading labels for each round.
round_heads = [h.get_text(" ", strip=True) for h in bsoup.find_all(["h2", "strong"])][:20]
print("round/heading labels sampled:", round_heads)


# ====================================================== (B) stat-cat boundaries
print()
print("=" * 70)
print("(B) STAT-CATEGORY TRACKING BOUNDARIES — basic-box columns per era")
print("=" * 70)
# (year, month, day) picks a mid-season date likely to have games.
probes = [
    (1972, 12, 1, "pre-steals/blocks era (expect no STL/BLK/TOV/3P, no OREB/DREB split)"),
    (1974, 12, 1, "1974-75 (expect STL/BLK + OREB/DREB; no TOV; no 3P)"),
    (1978, 12, 1, "1978-79 (expect TOV; no 3P)"),
    (1980, 12, 1, "1980-81 (expect 3P present — full modern basic box)"),
]
for (y, m, d, expectation) in probes:
    print(f"\n--- {y}-{m:02d}-{d:02d}: {expectation} ---")
    try:
        slug = first_slug_on(y, m, d)
        if not slug:
            print("  no games found on that date; try another date")
            continue
        cols = basic_box_columns(slug)
        first_tbl = next(iter(cols.values()), [])
        print(f"  slug={slug}  basic-box columns: {first_tbl}")
    except Exception as exc:  # read-only probe; surface but keep going
        print(f"  fetch/parse error: {exc!r}")
