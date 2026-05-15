# BR Page Shapes

Basketball-Reference HTML page structures discovered during POC. All content is server-side rendered — no JS execution required. Use `requests` + `BeautifulSoup` with `html5lib` parser.

---

## Games-of-day index

**URL:** `https://www.basketball-reference.com/boxscores/?month={M}&day={D}&year={Y}`

- No leading zeros on month/day (e.g., `month=1&day=5&year=2024`)
- Returns a list of game links on the page
- Game links match the pattern: `href="/boxscores/YYYYMMDD0HOME.html"`
  - `YYYYMMDD` — date
  - `0` — literal zero (separator)
  - `HOME` — 3-letter team abbreviation of the home team (uppercase)
- If no games that day, the page still loads but contains no matching links (off-season / off-day)

**Parsing approach:**
```python
import re
slugs = re.findall(r'/boxscores/(\d{8}0[A-Z]{3})\.html', html)
```

---

## Box score page

**URL:** `https://www.basketball-reference.com/boxscores/{slug}.html`

**Example:** `/boxscores/20231025ODALAS.html` (Wembanyama's debut — note: BKN is BRK, etc.)

**Size:** ~400-600KB HTML per game.

### Visible tables (standard BS4 parsing)

| Table ID | Rows | Cols | Content |
|----------|------|------|---------|
| `box-{HOME}-game-basic` | Up to 14 players + totals row | 22 | Basic box score for home team |
| `box-{AWAY}-game-basic` | Up to 14 players + totals row | 22 | Basic box score for away team |
| `box-{HOME}-game-advanced` | Up to 14 players + totals row | 17 | Advanced stats for home team |
| `box-{AWAY}-game-advanced` | Up to 14 players + totals row | 17 | Advanced stats for away team |

`{HOME}` and `{AWAY}` are 3-letter team abbreviations. Derive from the slug:
- Slug `20231025ODALLAS` -> home = `DAL`, away derived from visiting team score section
- Safer: parse the `<h2>` elements or look for the two distinct box-{TEAM} IDs in the page

### Multi-level column headers

Basic and advanced box tables have **two-level column headers** (pandas `MultiIndex`). When reading with `pd.read_html()` or BS4, the headers come back as tuples like `('Basic Box Score Stats', 'MP')`. Flatten them before processing:
```python
df.columns = [' '.join(col).strip() if isinstance(col, tuple) else col for col in df.columns]
```

### Totals row

Each box table has a "Team Totals" row at the bottom with player_name/starters label as empty or "Team Totals". Drop it before flattening:
```python
df = df[df['Player'] != 'Team Totals']
df = df[df['Player'].notna()]
```

### Hidden tables (comment extraction)

Two tables are wrapped in HTML comments and invisible to standard BS4 parsing. Extract them first:
```python
from bs4 import BeautifulSoup, Comment

soup = BeautifulSoup(html, 'html5lib')
comments = soup.find_all(string=lambda text: isinstance(text, Comment))
for comment in comments:
    inner = BeautifulSoup(comment, 'html5lib')
    tables = inner.find_all('table')
    for t in tables:
        table_id = t.get('id', '')
        # table_id will be 'line_score' or 'four_factors'
```

| Table ID | Rows | Cols | Content |
|----------|------|------|---------|
| `line_score` | 2 (home + away) | 6+ | Quarter-by-quarter scoring |
| `four_factors` | 2 (home + away) | 7 | Pace, eFG%, TOV%, ORB%, FT/FGA, ortg |

### line_score column structure

| Col | Description |
|-----|-------------|
| Team | Team abbreviation |
| 1 | Q1 points |
| 2 | Q2 points |
| 3 | Q3 points |
| 4 | Q4 points |
| OT (if applicable) | Overtime period points |
| T | Total points |

OT columns appear only if the game went to overtime. Handle up to 4 OT periods (OT1–OT4).

### Page metadata (regex extraction)

Officials, attendance, and inactive players are in `<div>` elements, not tables. Parse from page text:

```python
# Officials
import re
officials_match = re.search(r'Officials:.*?<a[^>]+>([^<]+)</a>', html)
# More robust: find all <a> tags after the "Officials:" label

# Inactive players
inactive_match = re.search(r'Inactive:\s*(.*?)</p>', html, re.DOTALL)

# Attendance
attendance_match = re.search(r'Attendance: ([\d,]+)', html)
```

---

## Monthly schedule

**URL:** `https://www.basketball-reference.com/leagues/NBA_{year}_games-{month}.html`

- `{year}` — the season end year (e.g., `2024` for the 2023-24 season)
- `{month}` — lowercase full month name (e.g., `october`, `november`, ..., `june`)
- Table ID: `schedule`
- ~12 columns: date, time, visitor, visitor_pts, home, home_pts, box_score_link, OT, attendance, notes

**Quirk:** Regular season runs Oct–Apr; playoffs run Apr–Jun. The June page may not exist in non-playoff years. Handle 404 gracefully.

---

## Annual draft

**URL:** `https://www.basketball-reference.com/draft/NBA_{year}.html`

- `{year}` — the draft year (e.g., `2023` for the 2023 draft)
- Table ID: `stats` (note: not `draft`)
- ~22 columns: pick, team, player, college, years played, career stats (G, MP, PTS, TRB, AST, FG%, 3P%, FT%, MP/G, PTS/G, TRB/G, AST/G, WS, WS/48, BPM, VORP)
- Multi-level headers: top level is section name, second level is column name — same flattening approach as box scores

**Career stats update in real-time** — fetching this page in the weekly_meta job gives current career stats for all draftees.

---

## Team season page

**URL:** `https://www.basketball-reference.com/teams/{ABBR}/{YEAR}.html`

- `{ABBR}` — 3-letter team abbreviation (BR style; some differ from NBA style: `BRK` not `BKN`, `NOP` not `NOH`, etc.)
- `{YEAR}` — season end year

Used for: arena, capacity, head coach, general roster info.

**BR vs NBA team abbreviation mapping:**

| NBA abbr | BR abbr |
|----------|---------|
| BKN | BRK |
| CHA | CHO |
| NOP | NOP |
| PHX | PHO |
| SAS | SAS |
| GSW | GSW |

Most abbreviations match. **Three gotchas**: BRK/BKN, CHO/CHA, **PHO/PHX**. Empirically verified 2026-05-15 — these three are the only mismatches across all 30 current franchises. The team-id resolver in `daily_settle.py` handles them via CASE translation.

---

## Notes

- **Crawl-delay:** 3 seconds per `robots.txt`. The `br_client.fetch()` function enforces this with a `time.sleep(3)` after every request.
- **Backoff:** On HTTP 429 or 503, `br_client.fetch()` uses exponential backoff starting at 30s. After 3 retries, it raises.
- **Season boundary:** BR uses the season end year everywhere. "2023-24 season" is year `2024` in BR URLs.
- **Game slug format:** `YYYYMMDD0HOME` — the zero is literal and always present. HOME is the home team's BR abbreviation (may differ from NBA abbreviation per the table above).
