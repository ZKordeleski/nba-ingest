# Handoff: State of nba-ingest

> ## ✅ Rebuild complete (2026-06-22)
> The pure-Basketball-Reference rebuild is done. **Full history 1946-47 → 2025-26 is
> loaded** (~72K games), DNP discipline and NBA Cup Championship handling are correct in
> the spine, the daily cron (`v2_daily.yml`) is live against `ZK_NBA_V2`, and the audit is
> clean (quarantine empty; all caveats carry human provenance). The only remaining step is
> the deferred `ZK_NBA_V2 → ZK_NBA` rename (`REBUILD_PLAN.md` Phase 6).
>
> **Current sources of truth:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (how it
> works), [`docs/REBUILD_METHOD.md`](docs/REBUILD_METHOD.md) (why), and
> [`docs/REBUILD_PLAN.md`](docs/REBUILD_PLAN.md) (history + backlog + cutover).
>
> **Everything below is the V1 / early-rebuild session log, kept as historical context**
> (the JB-seed era, the source-mash that the rebuild replaced). It does not describe the
> current system.

---

Written 2026-05-14, updated same day after the seed-execution pass. This document *was* the single source of truth for the V1 build; for current state see the docs linked above.

---

## Update: Seed phase complete (2026-05-14, evening)

**All 11 seed CTASs have been refactored, executed, and validated against real data.** Snowflake now contains the full JB historical NBA dataset, ready for BR scrape backfill.

### What was done in the seed pass

1. **Pattern refactor**: All 11 seed files converted from `CREATE OR REPLACE TABLE AS SELECT` to `TRUNCATE + INSERT`. This preserves column comments, table comments, and PRIMARY KEY declarations from `040_flat_tables.sql` — previously, CTAS clobbered all DDL metadata. `040_flat_tables.sql` is now also re-runnable (`CREATE OR REPLACE TABLE`).
2. **Type fixes**: 6 categories of type errors caught and corrected against real source schemas — `TRY_TO_NUMBER` refuses `NUMBER(38,1)→NUMBER(38,0)`, requiring `::INT`; PCT cols differ in scale between PS1/PS2; LINE_SCORE mixes NUMBER and VARCHAR; PCTIMESTRING is `TIME(9)` not VARCHAR; PLAYERS2 booleans are real BOOLEAN; DRAFT_COMBINE_STATS has 80+ cols including 27 shot-spot variants.
3. **Column-name corrections**: 5 wrong references caught (`TEAM_ID` vs `ID`, `GLEAGUEAFFILIATE` vs `DLEAGUEAFFILIATION`, `HOME_TEAM_ABBREVIATION` vs `TEAM_ABBREVIATION_HOME`, etc.).
4. **Data-quality normalizations**:
   - `line_scores`: regulation games encoded as `0/0` for OT periods → normalized to NULL. Real OT count now 3,290 (~5.7%, matches NBA reality of ~6%).
   - `team_history`: JB's `2100` "still active" sentinel → NULL via `NULLIF`.

### Final row counts (all from real seed execution)

| Table | Rows | Notes |
|---|---|---|
| games | 65,642 | 1946-11-01 → 2023-06-12, 0 NULL home_pts, 56 dupes dedup'd |
| player_box_basic | 1,568,763 | 1946-11-26 → 2025-04-06, Preseason filtered |
| line_scores | 58,053 | 3,290 real OT games (~5.7%, fix worked) |
| game_officials | 70,941 | 235 refs, 23,575 games |
| game_inactives | 110,191 | 20,312 games |
| players | 6,533 | 1,975 NULL position (JB gap) |
| teams | 30 | 5 NULL arena/coach (ORL/NYK/BOS/CLE/NOP — predicted) |
| team_history | 72 | NBA only; OKC: Seattle 1967-2007 + OKC 2008-NULL |
| draft | 7,990 | 1947-2023; #1 2023 = Wembanyama ✓ |
| draft_combine | 1,202 | 2001-2023 |
| play_by_play | 2,416,774 | 5,337 games, modern only |

### Ground-truth spot checks (all PASS)

- Wilt's 100-pt game (1962-03-02): 100/25/36, 63 FGA ✓
- Kobe's 81 (2006-01-22): 81/6/28, 46 FGA ✓
- Luka's 73 (2024-01-26): 73/10/25, 33 FGA ✓
- First NBA game (1946-11-01): NYK 68 vs HUS 66 ✓
- 2023 Finals G5: Nuggets 94, Heat 89 ✓
- 2023 Finals G5 line score: DEN 22/22/26/24, MIA 24/27/20/18 ✓
- 2023 Draft top 5: Wembanyama / Miller / Henderson / A. Thompson / Au. Thompson ✓
- 2023 G5 full box (15 players, Jokic 28/4/16, Murray 14, Butler 21, Bam 20) ✓

### Known data gaps (acceptable / fillable)

| Gap | Count | Cause | Disposition |
|---|---|---|---|
| Orphan player_box rows: 2024-25 seasons | 53,069 | FLAT.games stops at 2023-06-12 | **BR scrape fills** (by design) |
| Orphan player_box rows: 1958-1977 | ~88K | JB GAME table missing some early games (PS2 broader) | Accept — bonus history |
| line_score Q-sum mismatches: 1946-1957 | 1,051 | Pre-modern era only recorded totals | Accept — historical limitation |
| line_score Q-sum mismatches: post-1960 | 13 | Anomalies in JB | Accept (negligible) |
| NULL position in players | 1,975 | JB didn't populate GUARD/FORWARD/CENTER flags | Accept; BR scrape could backfill |
| LeBron's player metadata | 1 player | JB gap for player_info on some stars | Accept; cosmetic only |
| Wembanyama draft_combine | 1 player | He skipped the 2023 combine | Correct, not a bug |

### Verdict (Directive 2): **Keep the seed. Do NOT discard for scrape.**

Every ground-truth value matches reality exactly across 77 years of basketball. The gaps are inherent to data availability, not JB's ingestion. Scraping wouldn't improve the matched data and would only re-pull what we already have correctly. The 2023-25 gap is the **designed boundary** for BR scrape, not a JB flaw.

### Real game_id format (informs architectural decision #1)

NBA's canonical 8-char numeric format: `[type][YY][seq]` where type=2 (regular season), 4 (playoffs), 5 (play-in); YY=season start year (2-digit); seq=5-digit. Examples: `42200405` (2022-23 playoffs game 405), `24600001` (1946-47 game 1). All 65,642 game_ids are exactly 8 characters. Same format as the NBA Stats API uses.

---

## Update: Slice A complete (2026-05-14, evening cont.)

**The game → Snowflake pipe is proven end-to-end and idempotent.** A single BR-scraped game now lives in `FLAT.games` alongside the 65,642 JB-seeded rows.

### What landed in Slice A

1. **`flatten_game_row` in `flatteners/boxscore.py`** — derives one wide team-level row from the home/away "Team Totals" rows of the basic box. Adds `_extract_team_totals` helper and `_season_from_slug` (NBA season = end year, derived from slug date).
2. **`daily_settle.py` rewritten as Slice A only** — fetch one slug → flatten → MERGE into `FLAT.games`. Default slug `202404090MEM` (SAS @ MEM, Apr 9 2024). Override via `SETTLE_SLUG` env var. Loads `.env` with `override=False` so CI-injected vars win in production.
3. **`sql/010_stage.sql` adds `ZK_NBA.RAW.JSON_FF`** — reusable named JSON file format. Required because `SELECT FROM @stage` rejects inline `FILE_FORMAT => (TYPE = 'JSON')`; only named refs are accepted.
4. **8 new unit tests** for `_season_from_slug` (3 cases) and `flatten_game_row` (5 cases). All 30 tests pass.

### End-to-end validation

- **First run**: `MERGE result: [(1, 0)]` — 1 inserted, 0 updated.
- **Second run** (same slug, idempotency): `MERGE result: [(0, 1)]` — 0 inserted, 1 updated. Row count stays at 1 for the game_id. Total `FLAT.games` count: 65,643 (one new). `fetched_at` advances between runs.
- **Row contents verified against BR ground truth**:
  - game_id=`202404090MEM`, game_date=`2024-04-09`, season=2024
  - home=MEM 87 (L), away=SAS 102 (W), source=`br_scrape`
  - Stats present: home 36-104 FG, 6-30 3PT, 49 reb, 21 ast / away 42-87 FG, 10-40 3PT, 51 reb, 30 ast, 11 blk (Wembanyama on SAS roster — block count tracks)

### Slug format clarification

HANDOFF earlier listed `20240409OMEM` (12 chars with letter `O`). The **real BR slug** is `202404090MEM` — `YYYYMMDD + "0" (digit zero) + HOME` = 12 characters. Updated `DEFAULT_SLUG` and tests to use the correct format. JB game_ids stay 8-char numeric; BR slugs are 12-char — the two are unambiguously distinguishable by length.

### What is NOT in Slice A yet (correctly deferred to later slices)

- `season_id`, `season_type`, `home_team_id`, `away_team_id`, `home_plus_minus`, `away_plus_minus` — left NULL. The first three need an NBA Stats API lookup or schedule-page parse (Slice G). Plus_minus at team level is always 0 in BR's totals row; leaving NULL preserves the "we don't have this" signal.
- Player box, line scores, advanced stats — Slice B-D scope.
- Officials, inactives — Slice E-F scope (depend on architectural decision #2).
- Multi-game daily loop — Slice G scope.

### Why this matters

The job → MERGE → FLAT pattern is now de-risked. Slices B-F can copy this structure: build a new flattener, add a MERGE block, validate one game at a time. The architectural questions about game_id collisions can be deferred — JB's 8-char IDs and BR's 12-char slugs coexist cleanly today.

---

## Update: Slice B complete (2026-05-14, evening cont.)

**Player_box_basic now writes alongside games.** Same game `202404090MEM` produces 1 game row + 24 player rows in a single `settle_one()` call, fully idempotent.

### What landed in Slice B

1. **`PLAYER_BOX_BASIC_MERGE_SQL` in `daily_settle.py`** — MERGE statement keyed on `(game_id, player_name)` since BR player_id isn't extracted yet (decision #3 deferred).
2. **`_merge_rows()` helper** — generic PUT+MERGE wrapper that takes (rows, sql template, label, slug, tmpdir) and returns (inserted, updated). Both games and player_box use it now.
3. **Refactored `settle_one()`** — flattens both game-grain and player-grain rows from a single fetched boxscore, MERGEs both atomically (one tmpdir, one connection).
4. **`STAGE_PATH` simplified** — was `@ZK_NBA.RAW.INGEST_STAGE/flat/games`, now `@ZK_NBA.RAW.INGEST_STAGE/flat`. File label in NDJSON path distinguishes target table (`games_<slug>.ndjson`, `player_box_basic_<slug>.ndjson`).
5. **Synthetic `player_id` for BR scrapes** — flattener sets `player_id = player_name` for non-null compliance with the DDL. Documented as reversible interim until BR player-slug extraction (decision #3). One new unit test asserts `player_id == player_name` for BR-scraped rows.

### End-to-end validation

| Check | Expected | Got |
|---|---|---|
| First run (games) | (1, 0) | (0, 1) — already inserted in Slice A run |
| First run (player_box_basic) | (24, 0) | **(24, 0)** ✓ |
| Second run (games) | (0, 1) | (0, 1) ✓ |
| Second run (player_box_basic) | (0, 24) | **(0, 24)** ✓ — idempotent |
| Player rows for this game | ~28 | 24 (both teams had 12 dressed) |
| Total player_box_basic | 1,568,763 + 24 | 1,568,787 ✓ |
| **Wembanyama** | 18 pts / 7 blk | **18 pts, 7 blk, +15 plus_minus** ✓ |
| Orphan player_box rows (JOIN to games) | 0 | 0 ✓ |
| Distinct teams in player_box for game | 2 | 2 (MEM home, SAS away) ✓ |
| Team-pts sum = `games.home_pts` | 87 | 87 ✓ |
| Team-pts sum = `games.away_pts` | 102 | 102 ✓ |

### Notable real-data confirmations

- Jordan Goodwin's 19-rebound line for MEM (10 pts / 19 reb / 0 blk / 36 min) — matches earlier validation review note.
- SAS team blocks total of 11 (validated in Slice A) decomposed as: Wembanyama 7, Mamukelashvili 1, plus 3 elsewhere on the SAS roster.
- Top 10 scorers all known NBA players from that 2024 season (no name-parsing failures).

### Tests

32 unit tests pass (one new: `test_flatten_player_box_basic_player_id_is_synthetic_name`). Player-id synthesis behavior is now locked into the test suite so future refactors can't silently revert.

---

## Update: Slice C complete (2026-05-14, evening cont.)

**Three tables now write atomically per `settle_one()` call: `games` + `player_box_basic` + `line_scores`.** Same game `202404090MEM`, all idempotent.

### What landed in Slice C

1. **`LINE_SCORES_MERGE_SQL` in `daily_settle.py`** — MERGE keyed on `game_id` (single row per game). Updates all quarter/OT columns + totals on re-run.
2. **`flatten_line_score` wired into `settle_one()`** — reads the hidden `line_score` comment table from the boxscore fetch, returns a single dict (or None if missing), passed through the same `_merge_rows()` helper. No new flattener code required.

### End-to-end validation

| Check | Expected | Got |
|---|---|---|
| First run (line_scores) | (1, 0) | **(1, 0)** ✓ |
| Second run (line_scores) | (0, 1) | **(0, 1)** ✓ idempotent |
| Total line_scores | 58,053 + 1 | 58,054 ✓ |
| BR-scrape line_scores | 1 | 1 ✓ |
| Quarter sums = home_pts | 25+24+12+26 = 87 | **87 ✓** |
| Quarter sums = away_pts | 16+32+29+25 = 102 | **102 ✓** |
| OT columns | NULL (regulation game) | NULL ✓ |
| line_scores.home_pts = games.home_pts | TRUE | TRUE ✓ |
| line_scores.away_pts = games.away_pts | TRUE | TRUE ✓ |

### Triple-source reconciliation

**Three independent parsings of the BR page produce identical team totals:**
- Team Totals row of basic box (Slice A → `games`)
- Sum of 24 player rows (Slice B → `player_box_basic`)
- Hidden `line_score` comment table (Slice C → `line_scores`)

All three say MEM=87, SAS=102. If any parsing was broken we'd see disagreement; the agreement is strong evidence the pipeline is correct.

### Narrative readable from the data

The line score reveals SAS's run: 16 Q1 (down 9), then 32-24 in Q2, then 29-12 in Q3 — outscored MEM by 25 in the middle quarters, never looked back. This is the kind of contextual story the friend can now query for any of the 2024-25 games we backfill.

---

## Update: Slice D complete (2026-05-14, evening cont.)

**Four tables now write atomically per `settle_one()`: `games` + `player_box_basic` + `player_box_advanced` + `line_scores`.**

### What landed in Slice D

1. **Fixed `flatten_player_box_advanced`** — the original version never extracted the `Player` column. Every row had `player_id=None` and no `player_name`, making the data unattributable. Now reads `player_name` and uses it as the synthetic `player_id` (same pattern as basic).
2. **DNP filter in advanced** — BR fills advanced cells with empty strings for DNPs. A row with both `TS% is None` and `BPM is None` is skipped (no advanced stats worth storing). 4 DNPs were correctly filtered for this game.
3. **`PLAYER_BOX_ADVANCED_MERGE_SQL`** — keyed on `(game_id, player_id)`. With synthetic ID convention, advanced rows JOIN cleanly to basic rows on the same key.
4. **Wired into `settle_one()`** — pulls home + away advanced DataFrames from the boxscore fetch, flattens both, MERGEs as a single staged file.
5. **Two new unit tests**: `test_flatten_player_box_advanced_player_id_is_synthetic_name` (verifies the fix) and `test_flatten_player_box_advanced_skips_dnp_rows` (locks in DNP filtering).

### End-to-end validation

| Check | Expected | Got |
|---|---|---|
| First run (advanced) | (~20, 0) | **(20, 0)** ✓ |
| Second run (advanced) | (0, 20) | **(0, 20)** ✓ idempotent |
| Advanced row count | 24 basic − 4 DNPs | 20 ✓ |
| **Wembanyama BPM** | populated, strong | **8.9** ✓ |
| Wembanyama net rating | strong positive | ORtg 106 / DRtg 87 = **+19** ✓ |
| BPM coverage | 20/20 | 20/20 ✓ |
| Advanced rows JOIN to basic on (game_id, player_id) | 0 orphans | 0 ✓ |
| Top game BPM | small-minutes outlier OK | David Duke Jr. 35.2 (3-min stint), then Wemby 8.9 |

### Wembanyama's advanced profile (one game, contextualizes basic)

| Metric | Value | Reading |
|---|---|---|
| TS% | 0.474 | Modest shooting efficiency |
| USG% | 29.5 | High usage (star-level) |
| ORtg | 106 | Strong scoring |
| DRtg | 87 | Excellent defense |
| BPM | +8.9 | High overall impact |
| Real basic line | 18p / 6a / 7r / **7 blk** / +15 | The 7 blocks explain the DRtg 87 |

Two independent stats systems (basic counting stats and advanced rate stats) tell the same story: Wembanyama was the most impactful player on the floor. 33 unit tests pass.

---

## Update: Slice G complete (2026-05-14, evening cont.)

**The daily multi-game loop works end-to-end and is idempotent.** A single `settle_date(d)` call settles all of a day's games into 4 FLAT tables atomically (well, per-game atomic; per-day batched).

### What landed in Slice G

1. **`settle_date(target_date)` function in `daily_settle.py`** — iterates `list_games_on_date(d)`, opens ONE Snowflake connection, processes each game through `_settle_game(slug, conn, tmpdir)` with shared connection + tmpdir. Per-game failures log and continue (one bad game doesn't halt the rest).
2. **`_settle_game(slug, conn, tmpdir)` extracted** — was the body of `settle_one`. Now takes conn + tmpdir so the daily loop can share them. `settle_one` is now a thin wrapper that opens its own resources.
3. **Three CLI modes via env vars**:
   - `SETTLE_SLUG=202404090MEM` — debug a single game
   - `SETTLE_DATE=2024-04-09` — settle a specific date
   - (neither set) — settle yesterday (cron mode)
4. **Removed `DEFAULT_SLUG`** and rewrote module docstring around the production cron contract.

### End-to-end validation (2024-04-09, 14 games)

| Check | Expected | Got |
|---|---|---|
| Game count for date | 12-15 per HANDOFF | **14** ✓ |
| Player_box rows | ~336-420 | **381** (avg 27/game) ✓ |
| Advanced rows | ~280-360 | **315** (avg 22/game) ✓ |
| Line scores | 14 | **14** ✓ |
| All games have all 4 tables | 14/14 complete | **14/14** ✓ |
| Wall time | ~3 min (BR's 3s crawl-delay × 14) | 3:03 ✓ |
| First-run inserts | new = all but the SAS@MEM from Slice A-D | games +13/~1 ✓ |
| Second-run inserts | 0 everywhere | **(0, 14) / (0, 381) / (0, 315) / (0, 14)** ✓ |

### Real-world plausibility checks

The 14 games include recognizable 2023-24 NBA matchups: LAL@GSW (Warriors 134-120), DEN@UTA (champs 111-95), TOR@IND (Pacers 140-123 — high-paced), SAS@MEM (Spurs 102-87 from earlier slices). All scores within plausible NBA ranges (87-140), no zeros or negatives.

### Throughput math

~13s per game = mostly BR's 3s crawl-delay (4 fetches per game). A full 1,230-game regular season backfill = ~4.5 hours. Playoffs (~85 games) = ~20 min. **Slice H (season backfill) is ready to run when the user is.**

### Slices E and F deferred

Both require architectural decision #2 (officials/inactives schema): how to reconcile JB's INT-typed `official_id` (NBA Stats API format like `1830`, `2530`) with BR's slug format (`<a href="/referees/davisma99r.html">`). The job runs without them today and writes all 4 unblocked tables; the daily cron is production-viable as-is for game/box/line_score data.

---

## Update: Slice H complete (2026-05-14, evening cont.)

**Season backfill is wired up and tested.** Replaces the fragile `os.environ` mutation hack with direct `settle_date(d)` calls. Adds a partial-range mode for testing or filling small gaps.

### What landed in Slice H

1. **`backfill.py` rewritten** from env-var-juggling-and-sys.exit-catching to a clean function-call loop. Imports `settle_date` from `daily_settle` directly.
2. **Two CLI modes**:
   - `BACKFILL_SEASON=2023-24` — full season via BR's monthly schedule pages
   - `BACKFILL_DATES=YYYY-MM-DD,YYYY-MM-DD` — explicit date range
3. **`backfill_dates(dates: list[date])`** — extracted so other code (e.g., a future "fill the gap since the cron last succeeded" tool) can call programmatically. Aggregates counters across all dates.
4. **`.env` loading at module entry** — same `override=False` pattern as `daily_settle`.

### Validation: 2-day backfill (2024-04-10 to 2024-04-11)

| Metric | Got |
|---|---|
| Dates processed | 2/2 (both had games) |
| Games settled | 13 (8 on 2024-04-10, 5 on 2024-04-11) |
| Per-date counts | Day 1: 8, Day 2: 5 — matches BR's schedule |
| Wall time | ~5 minutes for 13 games |

### Cumulative state across Slices A-H

| Table | BR rows | Per-game avg |
|---|---|---|
| games | 27 | — |
| player_box_basic | 730 | 27/game |
| player_box_advanced | 606 | 22/game |
| line_scores | 27 | — |

**Cross-table integrity: every one of the 27 BR-scraped games has both a player_box row and a line_score row.** Zero orphans. The atomic-per-game pipeline holds.

### Ready to run when convenient

- **Full 2023-24 regular season backfill**: `BACKFILL_SEASON=2023-24 python -m nba_ingest.jobs.backfill` — ~4.5 hours, ~1,230 games. Closes the 2023-24 gap in FLAT.games.
- **Full 2024-25 season backfill**: same with `2024-25`. ~4.5 hours.
- **Together** these two backfills + the JB seed give the friend complete 1946-2025 coverage.

### Slices E, F, I still ahead

- Slice E (officials) + F (inactives): blocked by architectural decision #2.
- Slice I (weekly_meta): `weekly_meta.py` still has the three stub functions. Refresh draft career stats / teams / draft classes from BR — analogous patterns to Slices B-D but against draft-class pages.

---

## Update: Slice I.1 complete (2026-05-14, evening cont.)

**`refresh_draft_career_stats` is wired up and validated.** `weekly_meta.py` now writes live BR career stats for recent draft classes into `FLAT.draft_career_stats`. The other two substops (`refresh_teams`, `refresh_draft_classes`) remain documented TODOs requiring net-new fetchers/flatteners.

### What landed in Slice I.1

1. **`weekly_meta.py` rewritten** — replaces stub functions with a real `refresh_draft_career_stats(years)` implementation using `fetch_draft_class` (already existed) + `flatten_draft_career_stats` (already existed) + new `DRAFT_CAREER_STATS_MERGE_SQL`.
2. **Mode selection**: `WEEKLY_META_YEARS=2020,2021,2022,2023,2024,2025` overrides the default `range(2020, current_year+1)`.
3. **Bug fix in `flatten_draft_career_stats`**: added `_safe_str()` helper. `str(pd.NaN)` was returning the literal string `"nan"` for missing `college` / `team_abbr` / `player_name` fields. Now `pd.isna()` short-circuits to `None`.
4. `refresh_teams` and `refresh_draft_classes` are now well-documented TODOs with concrete notes on what's needed (new BR team-page fetcher; new `flatten_draft_picks` for the FLAT.draft schema vs. the existing `flatten_draft_career_stats` for the career-stats schema).

### End-to-end validation (years 2023 + 2024)

| Metric | Got |
|---|---|
| Rows inserted (first run) | 118 (58 2023 + 60 2024) ✓ |
| Rows updated (second run, idempotent) | 118, 0 inserts ✓ |
| **Wembanyama 2023 career** | 181 games, **23.4 ppg / 11.0 rpg / 3.5 apg, BPM +7.4, WS 17.5** ✓ |
| 2024 #1 Zaccharie Risacher | 142 games, 11.1 ppg, ATL ✓ |
| 2024 #2 Alex Sarr | 115 games, 14.4 ppg, WAS ✓ |
| 2024 #3 Reed Sheppard | 134 games, 10.0 ppg, HOU ✓ |
| BPM coverage | 110/118 (8 played zero career games; no stats expected) ✓ |
| `college` for Wembanyama after fix | NULL (was `'nan'` before) ✓ |
| `college` for Brandon Miller | `Alabama` ✓ |
| `college` for Scoot Henderson | NULL (G League Ignite, no college) ✓ |

The fix gives the friend usable nullability so queries like `WHERE college IS NULL` correctly find non-college players (international + G League prospects), instead of having to special-case the string `'nan'`.

### Why this matters

The friend can now ask "show me 2023 rookies' career arcs" or "who's outperforming their draft slot" with live data that refreshes weekly. No manual seeding required for years beyond JB's 2023 cutoff.

### Slice I scope still ahead

- `refresh_teams` — needs new BR team-page fetcher (`/teams/{TEAM}/{YEAR}.html`) + flattener for arena / capacity / coach extraction. Goal: fill `arena`/`coach` for the 5 teams missing from JB seed.
- `refresh_draft_classes` — needs new `flatten_draft_picks` to extract pick-record columns (`person_id`, `round_number`, etc.) from the same BR draft pages. Will populate `FLAT.draft` for 2024 + 2025 (currently empty for those years).

Both are ~1-2 hours of work using the same patterns as Slices B-D / I.1. Unblocked.

---

## Update: Slices E + F complete (2026-05-14, evening cont.)

**All six FLAT tables now write atomically per `settle_one()` call:** games, player_box_basic, player_box_advanced, line_scores, **game_officials, game_inactives**. The full parity with the JB seed schema is achieved.

### What landed in Slices E + F

1. **`_parse_meta` extended** — now extracts (name, br_slug) pairs for officials and inactives instead of just names. Inactives are grouped by team via `<strong>TEAM</strong>` header parsing. Attendance regex also fixed (`&nbsp;` isn't `\s`).
2. **`resolvers/official_id.py`** — two-tier resolver (no BR-fetch tier; BR ref pages don't have NBA.com links). Tier 1 by br_slug, tier 2 by name. Defensive slug fallback for unmatched refs.
3. **`flatten_game_officials` + `flatten_game_inactives` flatteners** — pure functions that take meta dict + resolver output, emit rows for MERGE.
4. **`GAME_OFFICIALS_MERGE_SQL` + `GAME_INACTIVES_MERGE_SQL` in daily_settle** — MERGE keyed on `(game_id, official_id)` and `(game_id, player_id)` respectively. Both keys use canonical NBA Stats API ids (resolved at write time).
5. **DDL: `game_inactives.player_id` from INT → STRING** + new `br_player_slug` column. Same pattern as `player_box_basic`.
6. **Inactives reuse the player_id resolver** — inactive players ARE players, their slugs are already in `box["player_anchors"]`. Zero new resolver code; the existing `slug_to_nba` map covers them.
7. **6 new unit tests** — Slice E + F flatteners locked into the test suite.

### End-to-end validation (game 202404090MEM)

| Check | Got |
|---|---|
| **Officials inserted** | **3** (Curtis Blair `200832`, Robert Hussey `1628480`, Tom Washington `1199`) ✓ |
| **Inactives inserted** | **15** (9 MEM + 6 SAS) — all with real NBA ids ✓ |
| Officials resolved via tier-2 name match | 3/3 (no tier-3 needed, none would work) ✓ |
| Inactives JOIN to JB player_box_basic via player_id | 15/15 joinable ✓ |
| Officials JOIN to JB game_officials via official_id | 3/3 joinable ✓ |
| **Ja Morant career via single `player_id='1629630'`** | **337 JB games** retrievable in one query ✓ |
| Idempotency: 2nd run for game_officials | (0 inserted, 3 updated) ✓ |
| Idempotency: 2nd run for game_inactives | (0 inserted, 15 updated) ✓ |

### Notable real-data validations

- **Tom Washington `official_id = 1199`** is a 4-digit ID — he's been an NBA ref since 1995, registered very early in the NBA Stats API's history. Long-tail historical IDs preserved correctly.
- **The 9 MEM inactives are ALL their stars**: Bane, Jackson Jr., Morant, Smart, Rose, Watanabe. Data captures the late-season tank explicitly. The 12 who *played* were the deep bench (Goodwin, Pippen Jr., Clarke, etc.). 21 players total on the roster, 12 playing + 9 sitting = real-world reconciliation.
- **39 unit tests pass** (6 new for Slices E/F).

### Update: Data-quality audit + team_id fix (2026-05-15, later in the day)

While investigating Gap 1, we built `DERIVED.vw_team_box` and ran a parity check against `TEAMSTATISTICS`. The check failed in a surprising way — uncovering a much bigger issue than the gaps.

#### Bug discovered
**`FLAT.player_box_basic.team_id` was 100% NULL** across both pipelines (jb_seed AND br_scrape). Every team-level query off this table was producing collapsed-both-teams-into-one-row results. The bug was invisible because the column existed and was queryable — only the values were absent.

Audit revealed a wider footprint of the same class of bug (all "deliberately NULL'd" or "never resolved at write time"):

| Table | Source | Columns 100% NULL |
|---|---|---|
| `player_box_basic` | jb_seed | `team_id`, `team_abbr`, `season` |
| `player_box_basic` | br_scrape | `team_id`, `team_name`, `opponent_team_name`, `season`, `game_type` |
| `games` | br_scrape | `home_team_id`, `away_team_id`, `season_id`, `home_plus_minus`, `away_plus_minus` |
| `game_inactives` | br_scrape | `team_id` |

Healthy tables (confirmed): `player_box_advanced`, `line_scores`, `game_officials`, `players` (real historical sparsity, not a bug), `teams`, `team_history`.

#### Fix applied
1. **JB seed** (`sql/050_seed_from_jb/001_player_box.sql`): rewrote to resolve team_id via JOIN to `FLAT.team_history` on (`city || ' ' || nickname`) with date-range filter, plus look up team_abbr from `FLAT.teams`, plus derive season from game_date. Result: **1.65% NULL** (down from 100%) — remaining cases are pre-1965 BAA/defunct franchises that team_history doesn't cover.
2. **JB seed pattern fix**: changed `TRUNCATE` to `DELETE WHERE source='jb_seed'` so the seed no longer wipes BR rows as collateral damage. (Learned this the hard way mid-fix — recovered the BR rows via Snowflake time-travel.)
3. **BR backfill** (`dev/_backfill_br_team_ids.sql`): one-shot UPDATE on existing 104K+3,940+33,658 rows. Resolves team_id from `team_abbr` with BR→NBA abbreviation translation (BRK→BKN, CHO→CHA, PHO→PHX); derives `season`, `game_type`, `opponent_team_name`, `home/away_plus_minus` and `season_id`. Result: **0.0% NULL** across all fixed columns.

#### Parity-check outcome
- Finals Game 5 (DEN @ MIA, 2023-06-12): all 14 standard team stats match `TEAMSTATISTICS` exactly.
- Two expected diffs documented:
  - **TOV off by 1 (~25% of 911-game sample)**: NBA distinguishes player-attributed turnovers from "team turnovers" (shot-clock violations, etc.). Our SUM only captures player-attributed; `TEAMSTATISTICS` sums both. Known basketball-stats edge case, not a bug.
  - **Minutes off by 3-4 (~57% of sample)**: `minutes_played` is stored as INT (rounded down). 5 players × ~0.5 min rounding ≈ ~2-3 min off vs. JB's 240 official figure. Tracked as future enhancement; non-blocking.

#### Still open (tasks logged in session)
- **Task #24**: patch the remaining `sql/050_seed_from_jb/*.sql` seed files to use `DELETE WHERE source='jb_seed'` instead of `TRUNCATE`. Same footgun pattern exists in `002_games.sql`, `003_line_scores.sql`, `004_officials.sql`, `008_inactive.sql`.
- **Task #25**: integrate the team-id resolution lookup into `daily_settle.py` (post-MERGE UPDATE step using the same abbr→team_id pattern). Without this, tomorrow's cron run will write NEW BR rows with NULL team_id and we'll have to re-run the backfill periodically.

#### Update later that day: BR-canonical swap for season >= 2024
Discovered that JB's `GAME` table cuts off at 2023-06-12 while JB's `PLAYERSTATISTICS1/2` extends to 2025-04-06 — so JB player_box rows for 2023-24+ had orphan game_ids that didn't join to `games`. Plus BR's URL-slug game_ids and JB's NBA-Stats numeric game_ids meant the same physical game appeared as two rows under different keys.

Resolution: pick a clean source boundary at 2023-06-12.
- `season <= 2023` (NBA seasons ending Jun-2023 and earlier): `jb_seed` exclusively, NBA Stats numeric game_id.
- `season >= 2024` (NBA seasons starting Oct-2023): `br_scrape` exclusively, BR URL-slug game_id.
- No overlap. No same-game duplication. 100% cross-table join success within each era.

Verified: `Jokic 2024 = 91 games`, `2025 = 84`, `2026 = 71` (current playoffs). `Wembanyama 2025 = 46` games (matches real DVT-affected season).

Trade-off accepted: BR's `season_id`, `game_type`, and `plus_minus` for 2023-24+ are derived rather than NBA-Stats-API authoritative. Derivations spot-checked against known games — values match.

#### The view (`ZK_NBA.DERIVED.vw_team_box`)
Live and parity-verified. One row per team per game. Computed at query time via `SUM(...) GROUP BY (game_id, team_id)` over `player_box_basic`. Use this for any team-level query — DO NOT add a redundant aggregate table.

```sql
SELECT * FROM ZK_NBA.DERIVED.vw_team_box
WHERE team_id = 1610612743 AND season = 2026
ORDER BY game_date DESC;  -- "Nuggets games this season"
```

---

### Update: JB source coverage analysis (2026-05-15)

We use 11 of the 24 tables in `JB_HISTORIC_NBA`. Documented here for the next agent to assess whether any unused tables justify additional FLAT tables.

#### What we use (mapped to FLAT)

`GAME`→games, `LINE_SCORE`→line_scores, `PLAYERSTATISTICS1+2`→player_box_basic, `PLAY_BY_PLAY_PART001+002`→play_by_play, `OFFICIALS`→game_officials, `INACTIVE_PLAYERS`→game_inactives, `PLAYERS2`→players, `TEAM`+`TEAM_DETAILS`→teams, `TEAMHISTORIES`→team_history (NBA filter, 72 of 140 rows), `DRAFT_HISTORY`→draft, `DRAFT_COMBINE_STATS`→draft_combine.

#### What we skipped (low-value or redundant)

- **`GAME_INFO`** (58K rows): adds only ATTENDANCE + GAME_TIME (game duration). Mildly useful for modern games only.
- **`GAME_SUMMARY`** (58K): live-game state fields (status text, broadcaster, live clock). Most fields stale once game finishes; only `NATL_TV_BROADCASTER_ABBREVIATION` is trivia-interesting.
- **`TEAM_HISTORY`** (52, distinct from `TEAMHISTORIES`): same schema, smaller — appears to be a partial/older copy. Redundant.
- **`PLAYER`** (4,831): just name registry. PLAYERS2 has everything PLAYER has plus heights/weights/positions.
- **`LEAGUESCHEDULE24_25`** (1,305): single-season schedule. We derive schedules dynamically from BR's monthly pages.

#### Three meaningful gaps the next agent should evaluate

##### ~~Gap 1: `TEAMSTATISTICS` — narrative team stats~~  *(PHANTOM — empirically disproven 2026-05-15)*

Originally framed as the "most material gap." Empirical check showed it's not real:

| Column | Rows populated (of 143,464) | % |
|---|---|---|
| `BENCHPOINTS`, `BIGGESTLEAD`, `LEADCHANGES`, `POINTSINTHEPAINT`, etc. | 2,460 | **1.7%** |
| `COACHID` | **0** | **0.0%** |

Only ~1,230 games (out of 71,732) have any narrative stats populated, spanning a non-contiguous window 2007-10-19 → 2025-04-06. `COACHID` is completely empty across the entire table. The columns *exist* on `DESCRIBE` but the values are essentially absent.

**Action taken:** removed from the gap list. Standard team-level stats (PTS/REB/AST/etc.) are derivable from `FLAT.player_box_basic` via `ZK_NBA.DERIVED.vw_team_box` (added 2026-05-15) — no aggregate table needed.

**Lesson:** always verify column *population*, not just *existence*, before scoping enrichment work. A 9-character column name like `POINTSINTHEPAINT` is a tantalizing lie if it's 98% NULL.

##### Gap 2: `COMMON_PLAYER_INFO` (4,171 rows) — richer player metadata

Our `FLAT.players` is sourced from `PLAYERS2`. `COMMON_PLAYER_INFO` adds the following columns we don't have:

| Column | Notes |
|---|---|
| `POSITION` (string) | Clean `'G'`/`'F'`/`'C'`/`'G-F'` etc. — much better than our derived position from GUARD/FORWARD/CENTER booleans (which currently leaves ~30% of players NULL). |
| `JERSEY` | Jersey number |
| `SCHOOL`, `LAST_AFFILIATION` | More specific than `PLAYERS2.LASTATTENDED` |
| `ROSTERSTATUS` | active / inactive / retired |
| `SEASON_EXP` | Career year count |
| **`GREATEST_75_FLAG`** | Marks the NBA's 75 Greatest Players. Enables `SELECT * FROM players WHERE greatest_75_flag` — fun query. |
| `PLAYERCODE` | **Possibly an NBA-Stats-API equivalent of BR's slug.** If so, would have offered a cleaner mapping than our name-match resolver in Decision #3. Worth investigating empirically — `SELECT PERSONID, PLAYERCODE FROM COMMON_PLAYER_INFO WHERE PERSONID = 1641705` to see what Wembanyama's PLAYERCODE looks like. |

Only 4,171 rows (vs PLAYERS2's 6,533) — covers currently-active and recently-active players. Best implementation: enrich `FLAT.players` with these as new columns via LEFT JOIN at seed time.

##### Gap 3: `GAMES` (plural, 71,732 rows) — richer game metadata
Distinct from `GAME` (65,698) — 6,090 extra rows. Columns we don't have:

| Column | Notes |
|---|---|
| `ATTENDANCE` | Per-game attendance, all eras (we currently only capture this via BR meta for post-2023 games) |
| `ARENAID` | Which arena. Pairs naturally with TEAM.arena from our existing seed. |
| `GAMELABEL` / `GAMESUBLABEL` | "NBA Finals - Game 5", "Christmas Day", etc. — narrative tags |
| `SERIESGAMENUMBER` | Game 1/2/3/4/5/6/7 within a playoff series |
| `GAMETYPE` | Likely cleaner taxonomy than our current `season_type` |

The +6,090 extra rows over `GAME` are likely preseason + in-season tournament + All-Star games. Best implementation: add these as new columns to `FLAT.games` via LEFT JOIN at seed time.

#### Bonus discovery: `JEDDY.SYNTHETIC_QUARTERS` (65,698 rows)
Per-quarter detailed stats: FGA/FGM/3P/FT/REB/AST/STL/BLK/TOV/PF per quarter per team. Much richer than our `line_scores` (which only has points per quarter).

**Caveats:**
- Lives in `JEDDY` schema, not `PUBLIC` — suggests it's someone's personal experiment, not the JB curator's canonical output
- Name "SYNTHETIC" implies it was derived from play-by-play, not direct from NBA Stats API
- Quality may suffer for pre-1990s games where PBP coverage is partial

Worth a spot-check if the next agent wants to add it: query `SELECT * FROM JEDDY.SYNTHETIC_QUARTERS WHERE GAME_ID = 42200405` (2023 Finals G5) and compare Q-by-Q FG% to what BR reports for that game. If close, the data is usable.

#### Implementation effort estimates

| Gap | Effort | Pattern |
|---|---|---|
| ~~`FLAT.team_box_stats` from TEAMSTATISTICS~~ | **deleted** | Phantom gap (1.7% column population). Covered by `DERIVED.vw_team_box` view instead. |
| Enrich `FLAT.players` from COMMON_PLAYER_INFO | ~20 min | ALTER ADD COLUMN for new fields, UPDATE via LEFT JOIN at seed time. |
| Enrich `FLAT.games` from `GAMES` plural | ~15 min | Same LEFT JOIN pattern + ADD COLUMN. |
| Investigate PLAYERCODE | ~5 min | Single SELECT. If it's the BR slug, document as a future Decision #3.1 refinement (no code change required today; the resolver works). |
| Maybe-add `SYNTHETIC_QUARTERS` | ~30 min spot-check + 20 min add if validated | New flat table; CTAS pattern. |

**Total: ~40 min to close remaining gaps from the JB seed side** (down from 1.5h after Gap 1 deletion).

#### Decision framework for the next agent

Add each only if the friend will actually query it:

- ~~**TEAMSTATISTICS**~~: phantom gap, deleted. Team-level queries use `DERIVED.vw_team_box` instead.
- **COMMON_PLAYER_INFO**: add if the friend wants clean position strings (especially since ~30% of `players.position` is NULL) or wants the `GREATEST_75_FLAG` filter. Low risk, additive only.
- **GAMES plural metadata**: add if the friend cares about playoff series context (game 7 of the Finals) or attendance pre-2023. Worth doing alongside any other refresh.
- **PLAYERCODE investigation**: do this regardless — 5 minutes — to know if Decision #3's name-match resolver has a more elegant alternative for any future rebuild.
- **SYNTHETIC_QUARTERS**: skip unless the friend specifically wants per-quarter advanced stats. The "synthetic" caveat means it's not production data.

---

### Task #17 complete

Decisions #2 and #3 are now fully closed:
- **Decision #2** (officials/inactives schema): `official_id` STRING, `br_official_slug` column added. `game_inactives.player_id` STRING, `br_player_slug` column added.
- **Decision #3** (real NBA player_ids for everyone): 3-tier resolver lives, tested against 2025-26 rookies and active stars alike.

The friend can now query a unified database where every player_box, game_official, and game_inactive row uses canonical NBA Stats API IDs across the JB→BR seam. **There is no longer a reconciliation problem.**

---

## Honest assessment: salvage, don't restart

**The repo is ~70% solid and ~30% needs rewrite.** The foundation layers (SQL, fetchers, flatteners, client, tests) have been validated against real Snowflake and real BR data. The job layer (orchestration glue) is broken in ways that require a clean rewrite — but throwing out the validated foundation to start over would lose real work to avoid the messy 30% that needs rewrite anyway.

**The fundamental mistake the implementor agent made:** it built daily_settle, backfill, and weekly_meta as if they were independent files. They're actually the integration point of every other file. They should have been built last, vertical-slice by vertical-slice, after the foundation was proven. Instead they were sketched in parallel with everything else and never validated end-to-end.

---

## File-by-file state

### ✅ Validated and working (KEEP)

| File | What was validated | Bugs found and fixed |
|---|---|---|
| `sql/001_bootstrap.sql` | Run; ZK_NBA DB, 3 schemas, NBA_INGEST_WH all exist | None |
| `sql/010_stage.sql` | Run; INGEST_STAGE exists, type=INTERNAL | None |
| `sql/020_raw_tables.sql` | Run; 3 tables, payload is VARIANT | None |
| `sql/040_flat_tables.sql` | Run; 13 tables, pts is NUMBER, game_id is STRING | None |
| `sql/050_seed_from_jb/*.sql` (11 files) | Pre-seed validation against JB data | 4: preseason filter, GAME dedup, OVERALL_PICK=0 handling, officials DISTINCT |
| `dev/apply_sql.py` | Used for all SQL execution | dotenv loading |
| `src/nba_ingest/snowflake_client.py` | Connection returns correct context | None |
| `src/nba_ingest/br_client.py` | fetch, parse, comment extraction | 3: missing lxml, StringIO wrap, narrowed exception |
| `src/nba_ingest/fetchers/games.py` | 14 games on Apr 9 2024; empty in off-season | None |
| `src/nba_ingest/fetchers/boxscore.py` | Wembanyama in SAS box; home=MEM, away=SAS | (home/away inversion fixed earlier) |
| `src/nba_ingest/fetchers/schedule.py` | 157 April 2024 rows | None |
| `src/nba_ingest/fetchers/draft.py` | Wembanyama #1, Miller #2 | None |
| `src/nba_ingest/flatteners/boxscore.py` | Goodwin 10/19, Wembanyama 18/7blk, DNP=0 | 1: DNP should be 0 not None |
| `src/nba_ingest/flatteners/schedule.py` | Apr 9 14 games found by ISO date | 1: dates not ISO-formatted |
| `src/nba_ingest/flatteners/draft.py` | Wembanyama career 23.4 ppg, 11.0 rpg | 1: duplicate column names |
| `tests/test_flatteners.py` | 22/22 pass | 1: test asserted old broken behavior |

### 🔴 Broken or incomplete (REWRITE)

| File | Problem |
|---|---|
| `src/nba_ingest/jobs/daily_settle.py` | Only writes player_box_basic. Misses 5 tables: games, player_box_advanced, line_scores, game_officials, game_inactives. Has explicit TODOs. |
| `src/nba_ingest/jobs/backfill.py` | Date parser fixed today, but file structurally depends on daily_settle being correct. |
| `src/nba_ingest/jobs/weekly_meta.py` | Entirely TODO stubs. No real implementation. |

### 🟡 Untested but probably works (LOW RISK)

| File | Why untested |
|---|---|
| `.github/workflows/daily_settle.yml` | Need GHA secrets configured + working daily_settle.py |
| `.github/workflows/weekly_meta.yml` | Same |
| `docs/plan.md` | Read for structure but not for accuracy — likely needs updates after rewrite |
| `docs/SETUP.md` | Same |
| `docs/SHAPES.md` | Documentation of BR page shapes; should be accurate but unverified |

---

## Validation results we have in hand

These are concrete, verified facts you can reference:

**JB_HISTORIC_NBA source data quality (against live Snowflake, 2026-05-11):**
- PS1: 811,672 rows, 2001-12-30 to 2025-04-06, complementary with PS2
- PS2: 811,671 rows, 1946-11-26 to 2001-12-30
- PS1/PS2 boundary has 0 overlapping (GAMEID, PERSONID) pairs — UNION is safe
- GAME: 65,698 rows, 65,642 distinct IDs (56 duplicates in 1930s-40s eras)
- GAME ends June 12, 2023 (DEN 94, MIA 89 — Finals G5)
- OFFICIALS: 70,971 assignments / 23,575 games (modern only)
- DRAFT_HISTORY: 7,990 picks 1947-2023; OVERALL_PICK=0 for 1948-1956 historical picks
- 5 teams missing from TEAM_DETAILS: ORL, NYK, BOS, CLE, NOP
- TEAM_DETAILS has 6 columns where stats are VARCHAR but cast cleanly with TRY_TO_NUMBER

**BR scraper validation (against live BR, 2026-05-14):**
- Fetch: ~0.2s + 3s crawl-delay per request
- Comment extraction: `line_score` and `four_factors` correctly retrieved
- Game Apr 9, 2024 SAS@MEM: SAS won 102-87, Wembanyama 18 pts/7 blk/7 reb/6 ast
- Quarter sums match totals: SAS 16+32+29+25=102 ✅, MEM 25+24+12+26=87 ✅
- 4 officials listed (Curtis Blair, Robert Hussey, Tom Washington)
- DNP players parsed correctly (Santi Aldama, Luke Kennard, Lamar Stevens, Ziaire Williams)
- 2023 Draft: Wembanyama #1 SAS, Miller #2 CHA, Henderson #3 POR
- Wembanyama career: 23.4 ppg, 11.0 rpg through 3 seasons, 17.5 WS

**Snowflake connectivity (2026-05-14):**
- User=zack.kordeleski@relational.ai, role=DEVELOPER_ADMIN, warehouse=NBA_INGEST_WH, database=ZK_NBA
- All 13 FLAT tables created with correct column types (pts is INT, game_id is STRING)
- All 3 RAW tables with VARIANT payload column
- INGEST_STAGE created as INTERNAL type

---

## Pending architectural decisions (must make before rewrite)

### Decision 1: `game_id` format

**Status:** Currently inconsistent. JB seed writes NBA numeric IDs (`42200405`). BR scrape would write slugs (`20230612ODEN`). Same column, different formats — joins broken.

**Recommendation:** Use BR slug as canonical `game_id` everywhere. Add `nba_game_id INT` as a secondary column for the JB numeric ID.

**Rationale:**
- Slugs are date-derivable from any source
- Human-readable in modeler queries
- Consistent across seeded and scraped data
- JB numeric ID preserved as a separate column

**Implementation cost:** One line in each of `002_games.sql` and `003_line_scores.sql`. Players table requires a JOIN through games to derive slug (since PS1/PS2 don't have home team abbreviation inline).

### Decision 2: Officials and inactives schema

**Status:** `FLAT.game_officials` PK is `(game_id, official_id INT)`. BR scraper extracts officials as a list of names with no IDs. Cannot insert.

**Options:**
- **A.** Extract BR official slug from `<a href="/referees/davisma01r.html">` anchor tags. Use slug as `official_id` STRING. Requires changing column type.
- **B.** Maintain a name → NBA official_id lookup table (built from JB OFFICIALS one-time)
- **C.** Use `(game_id, official_name)` as PK — degrades to fragile name matching
- **D.** Only populate officials from JB seed for historical games; skip for BR-scraped games

**Recommendation:** Option A (BR slugs) — symmetric with Decision 1, consistent across sources, parseable from existing HTML.

### Decision 3: Missing fields on BR rows

**Status:** `player_box_basic` from BR scrape has 7 None fields: `player_id`, `team_id`, `team_name`, `opponent_team_name`, `season`, `game_type`, `is_win`.

**All of these are derivable:**
- `player_id`: BR anchor `<a href="/players/j/jamesle01.html">` → "jamesle01"
- `team_id`, `team_name`: JOIN to `FLAT.teams` on `team_abbr`
- `opponent_team_name`: derivable from game home/away assignment
- `season`: derivable from `game_date` (NBA season starts October)
- `game_type`: derivable from `season_type` (regular/playoffs/play-in) via schedule context
- `is_win`: derivable from line_score comparison

**Recommendation:** Derive these at flatten time. Add a helper module `flatteners/derive.py` with one function per field.

---

## Vertical-slice rewrite plan for the job layer

Replace `daily_settle.py`, `backfill.py`, and `weekly_meta.py` by building **one table at a time, validated end-to-end before adding the next.** No file gets opened for the next table until the previous one is verified to write correctly.

### Slice A: Write a single game end-to-end (~2 hours)

Build `daily_settle.py` to do ONLY this:
1. Pick one BR slug (e.g., `20240409OMEM` — known data)
2. Fetch the box score
3. Flatten and write to `FLAT.games` — one row
4. Validate: row exists, correct teams, correct score, correct date
5. Re-run idempotently — verify MERGE doesn't duplicate

If this passes, the game→Snowflake pipe is proven. Only then move on.

### Slice B: Add player_box_basic (~1 hour)
1. Same game; add the basic box score table
2. Validate: ~28 player rows, Wembanyama 18 pts, idempotent
3. JOIN check: every player_box row has matching games row

### Slice C: Add line_scores (~30 min)
1. Same game; add line_scores
2. Validate: 1 row, quarter sums match home_pts/away_pts

### Slice D: Add player_box_advanced (~30 min)
1. Same game; add advanced stats
2. Validate: ~25-28 rows (one per non-DNP player), BPM populated

### Slice E: Make game_officials work (requires Decision 2 first)
1. Extract official slugs from BR HTML anchor tags
2. Add to `FLAT.game_officials`
3. Validate: 3-4 officials for a known game

### Slice F: Make game_inactives work
1. Parse inactives section
2. Reconcile name parsing fragility
3. Validate

### Slice G: Daily multi-game loop (~30 min)
1. Apply Slice A-F logic to `list_games_on_date(yesterday)`
2. Validate: 12-15 game rows, ~336-420 player rows
3. Run twice — verify idempotency

### Slice H: Backfill loop (~30 min)
1. Apply Slice G logic across all game dates in a season
2. Validate first season (2023-24): ~1,230 regular season + ~85 playoff games
3. Run twice — verify idempotency

### Slice I: Weekly metadata
1. `refresh_draft_career_stats` — pull 2020-2025 drafts, MERGE to draft_career_stats
2. `refresh_teams` — pull team season pages, UPDATE arena/coach for 5 missing teams
3. `refresh_draft_classes` — pull 2024 + 2025 drafts, INSERT to draft

---

## What's NOT in scope for the rewrite

- PBP backfill from BR (defer to a separate slice; JB has 8% coverage which is fine for v1)
- Modeler integration (separate project)
- Historical official slug → NBA ID mapping (one-time build, can defer)

---

## Order of operations (recommended)

1. **Run Slice 1 SQL (the seeding)** — already validated, no rewrites needed. Verify the data lands as expected against the spot checks. This proves the JB data is good in production.
2. **Make Decision 1 (game_id format)** — one architectural choice.
3. **Update SQL files** if Decision 1 changes the canonical ID. Re-run seed.
4. **Make Decision 2 (officials/inactives)** and Decision 3 (missing fields).
5. **Vertical-slice rewrite of job layer**, slices A through I, each validated against real data.
6. **Enable GHA cron** once daily_settle is validated end-to-end.

---

## Concrete next action

Run `sql/050_seed_from_jb/*.sql` against Snowflake (one at a time, with the validation spot-checks). This validates the seed data IS what we believe it is, and is independent of any job-layer decisions. It's also a quick win: ~5 min of compute time, gives us 1.5M+ rows of validated data, and the result is identical regardless of which game_id decision we make later (we just re-CTAS if we change the format).

Then make the architectural decisions with the data sitting there to inspect.

---

## Trust signals

Every validated file in this doc was tested against real data with explicit assertions. The bugs we caught:
- 3 critical (silent failures: column flattening, home/away swap, MERGE never updating)
- 4 important (data quality: preseason filter, duplicates, OVERALL_PICK=0, DNP stats)
- 4 minor (lxml missing, StringIO, date format, duplicate columns)

Total: **11 bugs caught by validating against real data.** None of these would have shown up in a code review. This is why the vertical-slice approach matters for the remaining job-layer rewrite.
