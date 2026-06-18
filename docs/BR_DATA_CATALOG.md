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
| Series label | page `<title>` + `<h1>` | playoff game only | **RESOLVED 2026-06-08** — lives in the `<title>`/`<h1>` text (`"2023 NBA Finals Game 5: …"`), NOT a `<strong>Label:</strong>` meta block. Parse round + game-number from `<h1>`. Authoritative structure also on the bracket page (see Phase 0 closeout findings below). |

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
| `meta.arena` | (in `scorebox_meta`) | **RESOLVED 2026-06-08** — arena/city/state is a pipe-delimited segment in `scorebox_meta`, not a `<strong>Arena:</strong>` block. Parse segment 2. See Phase 0 closeout finding D. |
| `meta.tv` (broadcast) | *never* | **confirmed absent 2026-06-08** — no network string on the boxscore page. Dropped from scope (finding E). |

---

### Phase 0 closeout findings — round/series + stat-availability (2026-06-08)

Two investigations via `dev/_phase0_probe.py` (read-only). Both feed `REBUILD_METHOD.md`.

**A. Playoff round / series is fully recoverable (closes the FINALS gap).** Two clean sources:

1. **Per-game** — the boxscore `<title>` and `<h1>` carry the full label: `"2023 NBA Finals Game 5: Miami Heat at Denver Nuggets Box Score, June 12, 2023"`. Round + game-number parse directly from `<h1>`. (The earlier `<h2>` regex missed it because the label is in `<title>`/`<h1>`, not a meta block.)
2. **Authoritative structure** — the bracket page `/playoffs/NBA_{year}.html` has an `all_playoffs` table and series-page links whose slugs encode round + matchup explicitly:
   - `/playoffs/2023-nba-finals-heat-vs-nuggets.html`
   - `/playoffs/2023-nba-western-conference-finals-lakers-vs-nuggets.html`
   - `/playoffs/2023-nba-eastern-conference-first-round-heat-vs-bucks.html`
   - Round heading labels: `East Conf 1st Round`, `East Conf Semis`, `East Conf Finals`, `Finals`.

*Design decision:* scrape the bracket page once per season → a `playoff_series` table `(season, round, series_slug, team_a, team_b, result, seeds?)`; tag each playoff game's `round` + `game_in_series` from its `<h1>` (and/or by joining to the series). `round` becomes a first-class, queryable value with `Finals` as a distinct label. This is the direct, durable fix for the bug that started the rebuild.

**B. ⚠️ Stat-availability CANNOT be inferred from column presence — BR's column template is uniform across all eras.** Confirmed by cell-value inspection:

| Season | `STL/BLK/ORB/DRB` cells | `TOV` cells | Meaning |
|---|---|---|---|
| 1972-73 (`197212010BAL`) | all `NaN` | all `NaN` | columns present, **data genuinely absent** |
| 1974-75 (`197412010LAL`) | populated | `NaN` | steals/blocks/ORB tracked from 1973-74; turnovers not yet |

A 1972-73 `box-*-game-basic` table *renders* `STL BLK TOV ORB DRB` headers, but every cell is `NaN`. So "the column exists" is **not** evidence the stat was tracked. Known NBA tracking-start seasons (domain ground truth, not scrapeable): **steals / blocks / offensive rebounds — 1973-74; turnovers — 1977-78; 3-pointers — 1979-80.**

*Design decision:* `metric_coverage` (per `REBUILD_METHOD.md` §3) is **authored from these domain breakpoints and verified against cell population** — never auto-derived from the scrape. The flatten step must treat a blank pre-tracking cell as *not-applicable* (governed by the no-ambiguous-NULL invariant), never coerce it to `0`. This is the stat-level instance of the FINALS-class ontology gap.

*Era-template note:* the basic-box first-column header is `Player` pre-1974 and `Starters` from ~1974; `GmSc` (Game Score, derived) appears from ~1978-79. (Minor flatten-parsing detail.)

**C. Per-quarter boundary tightened.** `box-{TTT}-qN-basic` present in **2001 and 2005** (8 tables = 4Q × 2 teams), absent in 1995. Boundary is **≤2001** (was "1995–2010, unpinned"). Good enough to scope `player_quarter_box` as a 2001+ table.

**D. `arena_name` RESOLVED (revises the "never" verdict).** Arena lives in `scorebox_meta` as a pipe-delimited segment — `"8:00 PM, April 9, 2024 | FedEx Forum, Memphis, Tennessee | …"` — **not** a `<strong>Arena:</strong>` block. Parse segment 2 (venue, city, state). The earlier "never matched" was a wrong-DOM-construct false negative, not absent data.

**E. `broadcast_network` confirmed ABSENT.** No `TNT`/`ESPN`/`ABC`/`NBA TV`/`TBS` anywhere in a 2024 boxscore page. **Drop from games-grain scope** (plan's Phase 1 already hedged this).

**F. Advanced columns populated pre-2001.** 1985 Finals G6 (`198506090BOS`) `box-*-game-advanced` has `TS% USG% ORtg DRtg BPM` **all populated** (Worthy .738/19.0/144/109/10.2). Disproves the "ORtg/DRtg/BPM may be NULL pre-1996" caveat — advanced box is fully usable from **≥1985**. (Still distinct from stat-availability per finding B: confirm via cells, not column presence.)

**Rate-limit check:** `robots.txt` → `Crawl-delay: 3`, matches `br_client.CRAWL_DELAY_SEC`. Sustained-throughput test folded into the Phase 1 ~95-game scrape (the real-world measurement).

---

### Source reconciliation discrepancies (old box scores) — 2026-06-10

Some pre-~1970s games have a small mismatch between a team's total and the sum of
its player rows (e.g. 1959-60 Lakers: Baylor 20 + … = 101, but BR's Team Totals =
103). **Root cause (confirmed via BR's own announcements): not our bug.** BR has
been adding *unofficial* game/player totals reconstructed from historical records —
team totals come from official league records, while player-level box scores were
separately sourced and are incomplete pre-1985-86. When old player data has gaps,
the player sum falls a few points short of the (known) team total.

Handling (Zack's call): **admit the real game + record a `reconciliation_discrepancy`
row in `FLAT.data_caveats`** (surfaced via `DERIVED.vw_data_caveats`) rather than
silently tolerate (blunts the guard) or exclude (loses real games). Egregious /
bug-sized mismatches (> `CAVEAT_RECON_MAX`) still quarantine. Magnitude is recorded
so future cleanup (or BR's ongoing unofficial-total additions) is easy to apply.

Sources:
- Sports-Reference — "Thousands of Unofficial Game-Level Totals Added to Basketball Reference": https://www.sports-reference.com/blog/
- Sports-Reference — "Several Dozen Newly Discovered Unofficial Totals Added" (2026-03): https://www.sports-reference.com/blog/2026/03/several-dozen-newly-discovered-unofficial-totals-added-to-basketball-reference/
- Sports-Reference — "Box Score For Every Game in NBA History" (2012): https://www.sports-reference.com/blog/2012/01/box-score-for-every-game-in-nba-history/

### Line-score discrepancies + adjudication methodology (BAA era) — 2026-06-11

BAA-era line scores (`/boxscores/{slug}.html` hidden `line_score` table) are
frequently **incomplete** (early quarters blank, total correct) or **absent**, and a
minority are **internally inconsistent** (all four quarters present but not summing to
the — corroborated — total). Provenance: BR's BAA box scores were assembled from
**local newspapers + microfilm** by a collector (Dick Pfander) and hand-curated over
decades, not from official league line scores ([Grantland](https://grantland.com/the-triangle/how-basketball-reference-got-every-box-score/)).
Quarter transcription imperfections are therefore *plausible*, but the specific cause
of any single game's discrepancy is generally **not independently confirmable** — so
caveats state the **observation**, never an assumed cause.

**Adjudication methodology (reusable — applied to the 11 quarantined 1947–49 games):**
1. **Corroborate the final two ways** — does the line-score `T` equal the summed box
   "Team Totals"? If yes (true for all 11), the game *outcome* is valid; only the
   quarter breakdown is in question.
2. **Rule out overtime with the minutes test** — team `MP` total = **240** ⇒ regulation
   (5×48); **>240** ⇒ overtime (e.g. 265 = 1 OT), which *explains* a quarters-short-of-total
   gap as uncaptured OT. This is the conclusive OT discriminator; BR's scorebox carries
   no reliable OT marker for this era, and a `\bOT\b` text search hits CSS noise — do
   **not** infer OT from the deficit size.
3. **Check for the parser swap** — `flatten_line_score` historically assigned home/away
   by row position; if the line rows are internally consistent but "disagree" with the
   game total, suspect a home/away swap (fixed 2026-06-11: match by team abbr).

**Outcomes (the 11):** 1 parser swap (`194802190BOS`, loads clean post-fix); 1 verified
OT (`194802280PRO`, MP=265, off by 1); 9 regulation games admitted with observation-only
`line_score_discrepancy` caveats (totals corroborated two ways; quarters off; cause
undetermined; refs in `review_note`). None held — every outcome was corroborated.

### `metric_coverage` ramp — `line_score_quarters`
Quarter completeness is a `recording_ramp` (incomplete early eras, ~full modern):
1947=74%, 1948=85%, 1949=97% complete. The audit's `line_score_completeness` detector
flags incompleteness only in a season that is otherwise ≥90% complete (a real anomaly),
treating a uniformly-sparse season as the documented ramp.

### Schedule enumeration — read months from the season index, not a fixed window (2026-06-17)
A season's games are split across **monthly** schedule pages
`/leagues/{lg}_{season}_games-{month}.html`. Enumerating a hardcoded Oct–June window
(the old `SEASON_MONTHS`) **silently drops any game outside it** — invisible because the
loaded games are each internally perfect; only a count-vs-known-schedule check exposes
the gap. Two COVID-distorted seasons proved it:
- **2020** — the Orlando bubble pushed play into **July, August, September** and a **dual
  October**: BR splits the season-start and the (Oct 11) Finals into `*-games-october-2019.html`
  and `*-games-october-2020.html`. A plain `*-october` fetch returns ONLY October 2019, so a
  fixed month list can't even *name* the Finals page. 172 games (incl. all playoffs) were missing.
- **2021** — the pandemic-shifted Finals ran into **July** (`*-games-july.html`); 8 games missing.

Fix: the season **index** `/leagues/{lg}_{season}_games.html` lists its own month-filter
links — `_season_month_pages()` parses those and enumerates exactly them (commit `a586832`),
so off-window schedules are read, not assumed. Verified across BAA→modern; an all-79-season
audit confirmed only 2020/2021 were ever affected.

### DNP zero-coercion (2025) + NBA Cup Championship mis-tag — 2026-06-18
Two modern-data defects found by the post-backfill audit + an analyst-query validation pass:

**DNP zero-coercion (2025 only):** the Phase-2 pilot-load basic-box flattener wrote DNP/inactive
players' stats as `0` instead of `NULL` (~6,843 rows, all box columns except `plus_minus`) —
violating NULL!=0. Comprehensively scoped to 2025 alone (1997-2024 NULL correctly; advanced box
NULLs correctly; early-era "hits" are minutes-proxy false positives). Externally validated (BR
boxscore `202410220BOS` lists "Baylor Scheierman Did Not Play"). Fixed by re-loading 2025 with the
current flattener. NOTE the discriminator is `minutes_played` (real 0s — played, scored 0 — have
minutes>0; ~1,325 exist in 2025), never the 0-ness of stats; ~11 sub-minute cameos (e.g. a 2-FT,
0:00 line) are real and correctly kept.

**NBA Cup Championship counted as Regular Season (2024 + 2025):** the Cup Championship game is the
ONLY tournament game that does NOT count toward regular-season stats or standings (group + knockout
+ semifinals all DO count — validated via NBA.com/Wikipedia/ESPN). Our schedule-index enumeration
captures it (good — it's a real game) but tagged it `Regular Season`, polluting the ~51 finalist
player-lines and inflating the RS game count to 1231 (vs 1230). Detection nuance: BR's scorebox_meta
labels it **`NBA Cup`** — but the **semifinals carry the identical label** and are also at the
neutral Las Vegas site, so the championship is distinguishable only as the **latest NBA-Cup game of
the season**. Fix applied: re-tagged `season_type='NBA Cup Championship'` on the two games
(`202312090LAL`, `202412170OKC`) + their `player_box_basic` rows, which restores exact official
values (SGA 76 GP / 32.7 / 51.9; Giannis 67 / 30.4). Games: `202312090LAL` (2023, LAL beat IND),
`202412170OKC` (2024, MIL beat OKC 97-81, Giannis tourney MVP). Durable ingest auto-tagging is a
tracked backlog item.

### Legacy caveat provenance remediation (full history) — 2026-06-17
At the post-backfill gate, 42 caveats predated the strict-guardrail provenance system
(observation but no `reviewed_by`). All re-reviewed per-game with evidence recomputed from
our own loaded data and signed (`dev/_remediate_provenance.py`, commit `bbccaa2`) → **110/110
data_caveats now carry full provenance**. Evidence framings: line-score discrepancies (quarters
incomplete but final corroborated 3 ways: line total == BR game final == box-score sum);
reconciliation discrepancies (player box missing historical rows; BR team total authoritative);
collisions (distinct same-name players). **Two games where BR self-contradicts by 2 pts** were
researched against an independent source (landofbasketball.com) and resolved in **opposite**
directions — `195403010MLH` stored final 71 was WRONG (corrected to 73; BR box+line + independent
all agree), `196312060SFW` stored final 101 was RIGHT (the line-score 103 is the artifact). The
lesson: when a source contradicts itself, internal majority-vote is unsafe — only an independent
source settles it.

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
