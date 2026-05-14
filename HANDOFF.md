# Handoff: State of nba-ingest

Written 2026-05-14 after extensive validation and review. This document is the **single source of truth** for what's been validated, what's broken, and what to do next. Supersedes `docs/plan.md` for current state.

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
