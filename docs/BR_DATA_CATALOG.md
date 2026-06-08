# Basketball-Reference Data Catalog

**Status**: Phase 0 in progress. Started 2026-05-20.

Produced under `REBUILD_PLAN.md` Phase 0. The data inventory in the rebuild plan tells us what we *want*; this catalog tells us what BR *has* — and surfaces things we didn't know to want.

Every section below is filled by *fetching real pages*, not by reading docs. Hypotheses go in `Predicted` columns; observations land in `Observed` after the fetch.

---

## 1. Page-type inventory

For every BR page type, capture:
- URL pattern (with example)
- Visible tables (id + grain)
- Hidden tables (comment-wrapped, id + grain)
- Meta blocks (free text, e.g., attendance / arena / broadcast)
- Era coverage notes

### 1.1 Boxscore page — `/boxscores/{slug}.html`

Example: `https://www.basketball-reference.com/boxscores/202404090MEM.html`

Slug format: `YYYYMMDD0TTT` where `TTT` is the BR 3-letter home-team code.

| Table id | Visible? | Grain | Status |
|---|---|---|---|
| `box-{TTT}-game-basic` | visible | player-game (basic) | known (per `flatteners/boxscore.py`) |
| `box-{TTT}-game-advanced` | visible | player-game (advanced, 2001+) | known; confirmed 2024 fetch |
| `box-{TTT}-q1-basic` … `q4-basic` | visible | player-quarter (basic) | **NEW — surfaced 2026-05-20 fetch**; not in plan inventory |
| `box-{TTT}-h1-basic`, `h2-basic` | visible | player-half (basic) | **NEW — surfaced 2026-05-20 fetch**; not in plan inventory |
| `line_score` | hidden (comment) | game (q1-q4 + OT) | known (per `br_client.py:115-119`); confirmed 2024 fetch |
| `four_factors` | hidden (comment) | game (eFG%, TOV%, ORB%, FT/FGA) | confirmed 2024 fetch |
| Officials list | meta block | game | known (per `resolvers/official_id.py`); confirmed 2024 fetch |
| Inactives list | meta block | player-game | known; confirmed 2024 fetch |
| Attendance | meta block | game | **confirmed 2024 fetch** — `<strong>Attendance:&nbsp;</strong>16,108` |
| Time of Game | meta block | game | **NEW — surfaced 2026-05-20 fetch** — `<strong>Time of Game:&nbsp;</strong>1:55` |
| Arena | meta block | game | regular-season 2024 fetch: **absent**; verify on marquee / playoff games |
| Broadcast network | meta block | game | regular-season 2024 fetch: **absent**; verify on TNT/ESPN games |
| Series label | page header | playoff game only | not present on regular-season fetch; verify on playoff fetches |

**Parsing gotcha** (recorded 2026-05-20): BR meta blocks use `&nbsp;` (HTML entity) between the label and the value, not whitespace. A future meta-block extractor must HTML-decode the chunk before regexing, or include `&nbsp;` in the separator pattern. `re.search(r'Attendance:</strong>\s*([\d,]+)', html)` returns `None` for this reason.

### 1.2 Player page — `/players/{l}/{slug}.html`

Example: `https://www.basketball-reference.com/players/j/jamesle01.html` (LeBron James)

Slug format: lowercase, first 5 letters of last name + first 2 letters of first name + 2-digit disambiguator. The `{l}` directory is the first letter of the last name.

| Section | What's there | Notes |
|---|---|---|
| Bio header | birth date/place, height, weight, shoots, college, HoF year | **verify granularity in era fetches** |
| Per-season totals | per-year stats table | basic + advanced + playoffs |
| Career stats | career totals + rates | |
| Game logs (per season) | separate page per season | follow link |
| Shooting tables | shot-distance + shot-type breakdowns | **verify era coverage** |
| Salary table | year × team × salary | **verify; if present, candidate for Phase 7 enrichment** |
| Awards | listed inline | useful for `awards` table cross-check |

### 1.3 Other page types

Status: **TODO in Phase 0**. One row per page type; URL pattern, what tables present, era coverage.

| Page type | URL pattern | Status |
|---|---|---|
| Team-season | `/teams/{ABBR}/{YEAR}.html` | TODO |
| Franchise | `/teams/{ABBR}/` | TODO |
| Coach | `/coaches/{slug}.html` | TODO |
| Official (referee) | `/officials/{slug}.html` | TODO |
| Schedule | `/leagues/NBA_{year}_games.html` | TODO |
| League season | `/leagues/NBA_{year}.html` | TODO |
| Awards | `/awards/awards_{year}.html` | TODO |
| All-Star game | `/allstar/NBA_{year}.html` | TODO |
| All-NBA / All-Defense | `/awards/all_league.html` | TODO |
| Draft | `/draft/NBA_{year}.html` | TODO |
| Standings | `/leagues/NBA_{year}_standings.html` | TODO |
| Season leaders | `/leagues/NBA_{year}_leaders.html` | TODO |
| Transactions | `/leagues/NBA_{year}_transactions.html` | TODO |
| Playoff bracket | `/playoffs/NBA_{year}.html` | TODO |
| Shot charts | `/boxscores/shot-chart/{slug}.html` | TODO (likely defer per plan §Q3) |
| Play-by-play | `/boxscores/pbp/{slug}.html` | TODO (likely defer per plan §Q2) |

---

## 2. Era sample fetches

The plan's eight era-test points. Picks are **canonical / iconic games** so the fetched page is information-dense. Slugs follow BR's `YYYYMMDD0TTT` pattern — they're guesses until the fetch succeeds.

| Era | Why this era | Game pick | Predicted slug | Player pick | Player slug guess |
|---|---|---|---|---|---|
| 1947 | BAA founding year | 1946-11-01 NYK @ TOR (first BAA game) | `194611010TRH` | Joe Fulks (BAA's first star) | `fulksjo01` |
| 1955 | First shot-clock season (1954-55) | 1955 Finals G7 SYR vs FTW | `19550410` + home? | Bob Cousy | `cousybo01` |
| 1965 | Pre-3pt, full shot-clock, expansion era | 1965 ECF G7 BOS vs PHI (Havlicek steal) | `19650415` + home? | Bill Russell | `russebi01` |
| 1975 | NBA-ABA parallel era | 1975 Finals G4 GSW @ WSB (sweep) | `19750525` + home? | Rick Barry | `barryri01` |
| 1985 | Post-3pt-line introduction | 1985 Finals G6 LAL @ BOS (clinch) | `19850609` + home? | Kareem Abdul-Jabbar | `abdulka01` |
| 1995 | Modern stats era kickoff | 1995 Finals G4 HOU @ ORL (sweep) | `19950614` + home? | Hakeem Olajuwon | `olajuha01` |
| 2010 | Full advanced-stats tracking era | 2010 Finals G7 BOS @ LAL | `20100617` + home? | Kobe Bryant | `bryanko01` |
| 2024 | Current era (regression-test baseline) | 2024-04-09 SAS @ MEM (per `daily_settle.py` default) | `202404090MEM` | LeBron James | `jamesle01` |

**To fill in by fetch**: exact slug (resolve home team), tables found (visible/hidden), meta blocks populated, advanced-stats presence (expect NULL pre-2001 per plan), is_starter extractable.

### Per-era findings (filled after fetch)

### 2024 — 2024-04-09 SAS @ MEM (fetched 2026-05-20)
- Slug verified: `202404090MEM` ✓
- HTML size: 464,281 bytes
- Visible tables (16): `box-MEM-game-basic`, `box-MEM-game-advanced`, `box-MEM-h1-basic`, `box-MEM-h2-basic`, `box-MEM-q1-basic`, `box-MEM-q2-basic`, `box-MEM-q3-basic`, `box-MEM-q4-basic`, plus the same eight for `SAS`.
- Hidden tables (2): `four_factors`, `line_score`
- Meta blocks present: Attendance (16,108), Time of Game (1:55), Officials (3 refs), Inactives (multi-team list)
- Meta blocks absent: arena_name, broadcast_network, series_label (likely because this is a regular-season game; re-verify on the 2010 Finals G7 fetch)
- Advanced box present? Yes (`box-MEM-game-advanced`, `box-SAS-game-advanced`)
- is_starter extractable? Not yet verified — needs to inspect the `box-MEM-game-basic` row structure (starters typically the first 5 rows before the "Reserves" header)
- Surprises: per-quarter and per-half player boxscores exist as separate visible tables (`q1-basic` through `q4-basic`, `h1-basic`, `h2-basic`). Plan didn't anticipate. See §4 surprise inventory.

### 1947 — 1946-11-01 NYK @ TRH (fetched 2026-05-20)
- Slug verified: `194611010TRH` ✓ (TRH = Toronto Huskies, BAA's first home team)
- HTML size: 164,482 bytes
- Visible tables (2): `box-NYK-game-basic`, `box-TRH-game-basic` (basic player box only)
- Hidden tables (1): `line_score` only — **`four_factors` ABSENT**
- Meta blocks present: none of attendance / time_of_game / officials / inactives / arena / tv matched
- Advanced box present? **No** — `box-{TTT}-game-advanced` not in table list
- is_starter extractable? Unknown — basic box only; needs DOM inspection
- Surprises: total absence of meta blocks. The first BAA game has no recorded attendance, no officials list, no inactives — BR doesn't expose this for the earliest games.

### 1955 — 1955-04-10 Finals G7 FTW @ SYR (fetched 2026-05-20)
- Slug verified: `195504100SYR` ✓ (Syracuse Nationals won their only title)
- HTML size: 170,382 bytes
- Visible tables (2): `box-FTW-game-basic`, `box-SYR-game-basic`
- Hidden tables (2): `four_factors`, `line_score` — **`four_factors` appears**
- Meta blocks present: attendance=`6,697`, officials=`Borgia, Eisenstein` (bare last names; no hyperlinks)
- Advanced box present? **No**
- Surprises: officials block uses bare last-name format. Resolver must accept this. attendance is *much* lower than modern era (~6.7K vs 16K+).

### 1965 — 1965-04-15 ECF G7 PHI @ BOS (fetched 2026-05-20)
- Slug verified: `196504150BOS` ✓ ("Havlicek stole the ball!")
- HTML size: 167,951 bytes
- Visible tables (2): `box-BOS-game-basic`, `box-PHI-game-basic`
- Hidden tables (2): `four_factors`, `line_score`
- Meta blocks present: attendance=`13,909`, officials=`Powers, Strom` (bare last names)
- Advanced box present? **No**

### 1975 — 1975-05-25 Finals G4 GSW @ WSB (fetched 2026-05-20)
- Slug verified: `197505250WSB` ✓ (Warriors' sweep of the Bullets — Rick Barry MVP)
- HTML size: 173,982 bytes
- Visible tables (2): `box-GSW-game-basic`, `box-WSB-game-basic`
- Hidden tables (2): `four_factors`, `line_score`
- Meta blocks present: attendance=`19,035`, officials=`Richie Powers, Manny Sokol` (full names now; still no hyperlinks)
- Advanced box present? **No**
- Boundary observation: official-name format shifts from last-name-only (1955, 1965) to full-name (1975). Hyperlinks still absent.

### 1985 — 1985-06-09 Finals G6 LAL @ BOS (fetched 2026-05-20)
- Slug verified: `198506090BOS` ✓ (Kareem leads Lakers' clinching win at Boston Garden)
- HTML size: 214,309 bytes
- Visible tables (4): `box-BOS-game-basic`, `box-BOS-game-advanced`, `box-LAL-game-basic`, `box-LAL-game-advanced`
- Hidden tables (2): `four_factors`, `line_score`
- Meta blocks present: attendance=`14,890`, time_of_game=`2:24`, officials=`Earl Strom, Hugh Evans`
- Advanced box present? **Yes** — **earlier than plan's assumed 2001 lower bound**. Caveat: must verify which advanced columns are populated; bpm/ortg/drtg may still be NULL pre-1996ish.
- Boundary observations: `time_of_game` first appears here (was absent 1947-1975).

### 1995 — 1995-06-14 Finals G4 HOU @ ORL (fetched 2026-05-20)
- Slug verified: `199506140HOU` ✓ (sweep clinch; **slug fallback used** — my G4-at-ORL guess was wrong, 2-3-2 format had G3/G4/G5 at HOU)
- HTML size: 213,080 bytes
- Visible tables (4): `box-HOU-game-basic`, `box-HOU-game-advanced`, `box-ORL-game-basic`, `box-ORL-game-advanced`
- Hidden tables (2): `four_factors`, `line_score`
- Meta blocks present: attendance=`16,611`, officials=hyperlinked `<a href='/referees/crawfjo99r.html'>Joe Crawford</a>, ...`
- Advanced box present? **Yes**
- Boundary observation: officials block now uses **hyperlinked anchors**. The official-resolver gets a clean external identifier from this era forward; older eras require name-only lookup.

### 2010 — 2010-06-17 Finals G7 BOS @ LAL (fetched 2026-05-20)
- Slug verified: `201006170LAL` ✓ (Kobe's title #5)
- HTML size: 453,420 bytes
- Visible tables (16): full set — `game-basic` + `game-advanced` + `q1-basic` … `q4-basic` + `h1-basic`, `h2-basic`, per team.
- Hidden tables (2): `four_factors`, `line_score`
- Meta blocks present: attendance=`18,997`, time_of_game=`2:47`, officials=hyperlinked, inactives=hyperlinked.
- Advanced box present? **Yes**
- Boundary observation: per-quarter / per-half tables appear here. Boundary is somewhere between 1995 and 2010 — needs a 2001-2005 sample to pin down. **Action item for follow-up fetches.**

### Era boundary summary

| Feature | First era seen | Notes |
|---|---|---|
| `box-{TTT}-game-basic` | 1947 | universal |
| `line_score` | 1947 | universal |
| `four_factors` | 1955 | first BAA game has none |
| `meta.attendance` | 1955 | first BAA game has none |
| `meta.officials` (bare names) | 1955 | last names only 1955-1965 |
| `meta.officials` (full names) | 1975 | first/last; still no anchors |
| `meta.officials` (anchored) | 1995 | hyperlinked to `/referees/{slug}.html` |
| `meta.time_of_game` | 1985 | absent in older eras |
| `box-{TTT}-game-advanced` | 1985 | **plan said 2001; revise** |
| `box-{TTT}-q1-basic` … `q4-basic` | 2010 | boundary between 1995-2010, unpinned |
| `box-{TTT}-h1-basic`, `h2-basic` | 2010 | same boundary |
| `meta.inactives` | 2010 | did not match in older eras (may be format diff) |
| `meta.arena`, `meta.tv` | *never* | the literal `<strong>Arena:</strong>` / `<strong>TV:</strong>` label was not present in any sampled era — needs raw-HTML inspection to find where arena_name & broadcast_network actually live, if anywhere |

---

## 3. Cross-page navigation map

The link graph between page types. The resolvers depend on this (e.g., `player_id` resolver follows the boxscore → player page → `stats.nba.com` external-link chain).

```
boxscore (/boxscores/{slug}.html)
  ├─ links to → player page (/players/{l}/{pslug}.html)   [drives player_id resolver]
  ├─ links to → team-season page (/teams/{TTT}/{YEAR}.html)
  ├─ links to → official page (/officials/{oslug}.html)   [drives official_id resolver]
  ├─ links to → play-by-play (/boxscores/pbp/{slug}.html)
  └─ links to → shot chart (/boxscores/shot-chart/{slug}.html)

player page
  ├─ links to → external stats.nba.com player id    [canonical bridge for player_id resolver]
  ├─ links to → game logs per season
  ├─ links to → splits per season
  └─ links to → awards / HoF page

(fill in: team-season, franchise, coach, official, league pages)
```

To fill: which page types lack outbound links (dead-end leaves), which links are conditional (modern era only), which break on era-specific pages.

---

## 4. Surprise inventory

Things BR has that the rebuild plan's data inventory didn't anticipate. Watch for these specifically; add freely beyond this list.

- [ ] Salary history per player (year × team)
- [ ] Contract data (current contracts, dead money)
- [ ] College career stats per player (per-season)
- [ ] International career stats per player
- [ ] Draft-prospect (pre-draft) pages with college / international stats
- [ ] Referee crew assignments (referee × game × crew_chief role)
- [ ] Scoring distribution by quarter / half / clutch
- [ ] In-season tournament / Cup standings (post-2023)
- [ ] G-League per-game stats (separate site? cross-link?)
- [ ] WNBA / international cross-links (out of scope but note)
- [ ] Streaks tables (longest win/loss streaks per team/season)
- [ ] Lineup data (5-man unit stats; possibly absent from BR)

### Surfaced 2026-05-20 (modern-era boxscore fetch)

- [x] **Per-quarter player boxscores** (`box-{TTT}-q1-basic` … `q4-basic`) — player-quarter grain, basic stat columns. Unlocks: best 4th-quarter scorers; verifies "Klay's 37-point quarter" (Phase 5 spot-check) directly. Boundary observed: present in 2010+, absent in 1995. **Pin the boundary** by sampling 2001 and 2005.
- [x] **Per-half player boxscores** (`box-{TTT}-h1-basic`, `h2-basic`) — same boundary as quarters.
- [x] **`Time of Game` meta block** — game-grain duration ("1:55" = 1h 55min). Low-value but trivially scrapable.
- Decision pending: should `player_quarter_box` and `player_half_box` be new tables in `ZK_NBA_V2`? Tradeoff: cheap to flatten alongside the game box, but bloats the schema. Reflect in Phase 0 reflection gate.

### Surfaced 2026-05-20 (era sample fetch, 1947→2010)

- [x] **Advanced box exists at least back to 1985** — `box-{TTT}-game-advanced` returned by the 1985 Finals G6 fetch. **Plan's data inventory says "back to 2001" — REVISE.** Caveat: column-level population needs verification; some metrics (bpm, ortg, drtg) require opponent context that may still be NULL pre-1996.
- [x] **Official-name format evolves across eras** — bare last names (1955, 1965) → full names (1975) → hyperlinked anchors (1995+). The `official_id` resolver already handles this in the seed pipeline (235 refs across 23,575 games), but any new official-page enrichment work needs an era branch.
- [x] **Earliest BAA games have NO meta blocks at all** — 1946-11-01 (first BAA game) has no attendance, no officials, no inactives. Plan should not assume universal meta coverage; the `games` table's `attendance` column will be ~100% NULL for ~1947-1954 games.
- [x] **`four_factors` first appears at 1955** — boundary between 1947 and 1955. Since it's derivable from basic box, this is BR's choice not to precompute, not a data limitation.

### Action items surfaced for sub-phases

- [ ] **Pin per-quarter boundary**: fetch 2001 and 2005 Finals games; record whether `box-{TTT}-qN-basic` is present.
- [ ] **Locate `arena_name` and `broadcast_network`**: grep raw HTML of the 2010 G7 fetch for `Garden`, `Arena`, `TNT`, `ABC`, `ESPN` — find what DOM construct holds them, if any. If absent everywhere, **revise plan's data inventory** (drop these from games-grain scope).
- [ ] **Verify advanced-column population pre-2001**: inspect 1985 G6's `box-LAL-game-advanced` row contents; record which columns are populated vs NULL. Different from "table exists."
- [ ] **`is_starter` extraction**: inspect the basic-box DOM in a modern (2010 or 2024) fetch for the visual separator between starters and reserves. Confirm the boundary signal (row class, blank row, etc.) is stable across eras.

For each surprise found: page URL, what fields, era coverage, "include in Phase 4 enrichment scrape?" decision.

---

## 5. Rate-limit reality check

`br_client.py:43` sets `CRAWL_DELAY_SEC = 3.0`. Verify against current `robots.txt` and observe behavior under sustained load.

| Check | Expected | Observed |
|---|---|---|
| `robots.txt` `Crawl-delay` directive | `3` | (fetch and paste) |
| Sustained throughput (10 min, ~50 pages) | ~200 pages | TBD |
| Effective throughput including retries | ≥190 pages / 10 min | TBD |
| 429 / 503 frequency | ~0 | TBD |
| IP-block evidence | none | TBD |

Also note: theoretical max for the full historical backfill is `~80,000 pages × 3s = ~67h`. Reality-check whether parallel workflows (multiple GHA runners) help or just trigger IP-level rate-limiting.

---

## Reflection gate output

Filled at the end of Phase 0. Append a `## Phase 0 Reflection — YYYY-MM-DD` section per `REBUILD_PLAN.md`'s template. Specifically resolve:

1. Updates to the data-inventory section of `REBUILD_PLAN.md` (anything Phase 0 surfaced as wanted/unwanted).
2. Which "new tables" (`standings`, `awards`, `all_stars`, `all_nba_teams`, `season_leaders`, `coaches`) are **confirmed-included** vs **deferred** to Phase 7.
3. Pre-1976 coverage decision: BR-only or keep JB fallback for the very-old era. (Open question #1 in plan.)
4. Phase 1 scope adjustments based on Phase 0 findings.
