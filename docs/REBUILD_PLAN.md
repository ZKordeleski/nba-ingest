# Rebuild Plan: Pure Basketball-Reference Architecture

**Status**: Approved 2026-05-19. Ready for the next agent to begin Phase 1.

---

## Why we're rebuilding

The current architecture mixes two sources — `JB_HISTORIC_NBA` (seeded from NBA Stats API) and Basketball-Reference (scraped) — with an explicit boundary at 2023-06-12. The session log in `HANDOFF.md` documents a long chain of bugs that all trace back to the *interaction* between sources (two `game_id` formats, encoding splits, table-cutoff inconsistencies inside JB itself, TRUNCATE-as-collateral-damage, the team_id resolver complexity). None of those bugs would exist in a single-source pipeline.

The current state is shippable, but every future change pays interest on the seam. We're choosing to pay the rebuild cost once instead of the friction tax forever.

Today's session was load-bearing for the rebuild: the BR fetchers, flatteners, player_id resolver, team-abbr translation, and post-MERGE resolution pattern are all reusable. We're not starting over — we're starting from a much more informed position.

---

## Architectural principles (carried forward from today's learnings)

These principles emerged from this session and should shape every rebuild decision:

1. **Single source per logical entity.** No mixed-source FLAT tables; no per-row `source` column needed because there's only one source.
2. **Explicit boundary documentation.** When BR genuinely lacks data for an era (e.g., advanced stats pre-2001, play-by-play pre-1996), document the era cleanly in column COMMENTs — not in agent-facing footnotes.
3. **Canonical entity resolution at write time.** Player_id, team_id, official_id all resolved during MERGE, not as post-hoc backfills. The resolvers we already built stay.
4. **MERGE everywhere; no TRUNCATE.** All writes are idempotent. Re-running on already-settled data is a no-op semantically.
5. **Schema metadata is load-bearing.** Column COMMENTs are read by the LLM agent at query time — every column gets an accurate, source-traceable comment.
6. **Empty tables are deleted, not documented.** If a loader isn't built yet, the table doesn't exist yet. No "WIP" tables.
7. **Audit before adding.** Verify column population, not just column existence, before scoping enrichment work. (The phantom Gap 1 lesson.)
8. **Verify reserved words upfront.** `rows` bit us four times today; pre-check Snowflake reserved-word lists when writing throwaway audit SQL.

---

## Data inventory: what we keep + what we want

Comprehensive list across three columns: *current state*, *value to the friend's queries*, *BR availability*. Every line item must have a "yes BR has this" before we commit to including it in the rebuild scope.

### Player-game grain (`player_box_basic`, `player_box_advanced`)

| Field | Have today? | Value | BR availability |
|---|---|---|---|
| game_id, player_id, player_name | ✓ | core | yes (slug + resolver) |
| team_id, team_name, team_abbr, opponent_team_name | ✓ | core | yes |
| game_date, season, game_type, is_win, is_home | ✓ | core | yes |
| minutes_played | ✓ (rounded INT) | core | yes (MM:SS — should preserve as FLOAT) |
| pts, ast, reb, oreb, dreb, stl, blk, tov, pf | ✓ | core | yes |
| fgm/fga/pct, fg3m/fg3a/pct, ftm/fta/pct | ✓ | core | yes |
| plus_minus | ✓ (partial) | core | yes |
| **is_starter** (BOOLEAN) | ✗ | medium — unlocks BENCHPOINTS-style queries | yes (BR boxscores mark starters) |
| ts_pct, efg_pct, fg3a_rate, fta_rate, orb_pct, drb_pct, trb_pct, ast_pct, stl_pct, blk_pct, tov_pct, usg_pct, ortg, drtg, bpm | ✓ (2023+ only) | high | yes, **back to 2001** (BR's coverage) |

**Improvements over current state**: store `minutes_played` as decimal (e.g. 36.13 for 36:08) instead of rounded INT — fixes the team-minutes sanity-check mismatch. Add `is_starter` for bench-stat queries.

### Game grain (`games`, `line_scores`)

| Field | Have today? | Value | BR availability |
|---|---|---|---|
| game_id, game_date, season, season_id, season_type | ✓ | core | yes (derive season_type from game_id pattern) |
| home/away_team_id, abbr, pts, wl | ✓ | core | yes |
| home/away aggregates (fgm/fga/.../plus_minus) | ✓ | core | yes |
| q1-q4 + ot1-ot4 per side | ✓ | core | yes (hidden line_score table) |
| **attendance** | ✗ | medium | yes (meta block on boxscore page) |
| **arena_name** (per-game) | ✗ | medium | yes (meta block) |
| **start_time** (local TZ) | ✗ | low | yes |
| **broadcast_network** (TNT, ESPN, ABC, etc.) | ✗ | medium — for "show me TNT Thursday games" queries | yes (when listed) |
| **series_label** ("NBA Finals - Game 5", "Eastern Conference Finals - Game 3") | ✗ | high — playoff context | yes (page header text) |
| **game_label** ("Christmas Day Game", "Opening Night") | ✗ | low | yes (sometimes in page metadata) |

### Officials (`game_officials`)

| Field | Have today? | Value | BR availability |
|---|---|---|---|
| game_id, official_id (resolved), first/last name, jersey_num | ✓ | core | yes (modern era only — pre-1980 BR doesn't list refs) |

### Inactives (`game_inactives`)

| Field | Have today? | Value | BR availability |
|---|---|---|---|
| game_id, player_id, name, team, jersey | ✓ | medium | yes (meta block, modern era) |
| **inactive_reason** ("Injury", "Personal", "G League assignment") | ✗ | low-medium | yes (BR notes injury reason in meta) |

### Player bio (`players`)

| Field | Have today? | Value | BR availability |
|---|---|---|---|
| player_id, first_name, last_name | ✓ | core | yes |
| birth_date, height_in, weight_lb, position | ✓ (partial, ~30% NULL on old players) | core | yes (BR has cleaner coverage for old players than JB had) |
| college, country | ✓ | medium | yes |
| draft_year, round, pick | ✓ | medium | yes |
| from_year, to_year | ✓ | medium | yes |
| **shoots** (L/R/B) | ✗ | low-medium — for "lefty leaders" trivia | yes |
| **birth_city / birth_state / birth_country** (granular) | ✗ (have country only) | low | yes (BR has all three) |
| **nicknames** | ✗ | low — fun trivia | yes (sometimes) |
| **hall_of_fame_year** | ✗ | high — "show me HoFers' rookie seasons" | yes (BR marks HoF inductees) |
| **jersey_number_history** (list of numbers worn) | ✗ | low | yes (BR season tables) |

### Team metadata (`teams`, `team_history`)

| Field | Have today? | Value | BR availability |
|---|---|---|---|
| team_id, abbreviation, full_name, city, year_founded | ✓ | core | yes |
| arena, arena_capacity (current) | ✓ (partial, 5 manually filled) | low | yes (BR team page) |
| head_coach (current) | ✓ (stale risk) | low | yes |
| g_league_affiliate | ✓ | low | maybe (less reliable) |
| team_history (city + nickname eras) | ✓ | medium | yes (BR franchise page) |
| **per-season team record** (W-L-PCT, conference rank, division rank) | ✗ | high — basis for "best team ever" queries | yes (BR team-season pages) |
| **per-season coach** | ✗ | medium — historical coach attribution | yes |

### Draft (`draft`, `draft_combine`, `draft_career_stats`)

| Field | Have today? | Value | BR availability |
|---|---|---|---|
| draft picks 1947-2023 | ✓ | core | yes through current year |
| **2024-2025 draft picks** | ✗ | medium | yes |
| combine measurements (height, wingspan, vert, etc.) | ✓ (~1,200 rows from JB) | low-medium | possibly (BR has some, NBA Combine page has more; investigate) |
| **draft_career_stats** populated | ✗ (table empty) | medium — career-arc queries on draft picks | yes (BR draft page has career totals, updates as careers progress) |

### Play-by-play (`play_by_play`)

| Field | Have today? | Value | BR availability |
|---|---|---|---|
| event_num, period, clocks, description, score, player1/2/3 | ✓ (modern games only, ~2.4M events) | high | yes (BR PBP page per game) |
| **shot_x, shot_y** (court coordinates) | ✗ | very high — heat maps, shot zones | yes (BR has shot chart pages, separate scrape) |
| **shot_distance** (feet from basket) | ✗ | high | yes (derivable from shot location) |
| **shot_zone** (paint, mid-range, corner-3, etc.) | ✗ | high | yes (derivable; BR sometimes labels) |

### Things we don't have at all but want (new tables)

These are listed even though we don't have them today, because the rebuild is the right moment to add them. All are scraped from BR pages we'd need to add to the fetcher list.

| New table | Grain | Source | Value |
|---|---|---|---|
| `standings` | (season, team_id) | BR `/leagues/NBA_{year}_standings.html` | "Best teams ever" / "1996 Bulls vs 2017 Warriors" queries |
| `awards` | (season, award_name) | BR `/awards/awards_{year}.html` | "MVP winners", "ROY history" |
| `all_stars` | (season, player_id) | BR `/allstar/NBA_{year}.html` | "Most All-Star selections" |
| `all_nba_teams` | (season, team_tier, player_id) | BR `/awards/all_league.html` | "All-NBA First Team history" |
| `season_leaders` | (season, stat_category, rank, player_id) | BR `/leagues/NBA_{year}_leaders.html` | "Scoring titles", "Top 10 in steals 1995" |
| `coaches` | (coach_id, season, team_id) | BR `/coaches/{slug}.html` | "Phil Jackson's career", "winningest coaches" |

These are all derivable from per-game data via aggregations, BUT pre-computed tables let the agent answer narrative questions ("MVP winners by decade") directly without complex window queries. **Add them if they're cheap to scrape** (most are 1 page per season).

---

## Phase plan

### Phase 1 — Validation (1 session, ~1-2 hours, no scraping commitment yet)

**Goal**: prove BR has what we need before committing to ~55 hours of scraping.

- Fetch and parse one sample game per era: 1950, 1962, 1975, 1985, 2000, 2010, 2024.
- For each: confirm we can extract player_box, line_score, officials (where applicable), meta block.
- Document era-specific gaps (e.g. "pre-1976: no per-player breakdown, totals only"; "1976-1995: no advanced stats from BR"; etc.).
- Run a 5-minute scrape against `/boxscores/?month=11&day=5&year=1949` to confirm date-index pages work that far back.
- **Outcome**: go/no-go on the rebuild. If BR's pre-1976 coverage is poor, course-correct (e.g. keep JB for pre-1976, BR for 1976+). If good, commit.

### Phase 2 — Parallel-build setup (~2-3 hours code)

**Goal**: scaffold a parallel `ZK_NBA_V2` database; reuse every existing code path.

- Create `sql/V2/` directory mirroring current `sql/` structure.
- Re-run our existing DDL (`040_flat_tables.sql`) against `ZK_NBA_V2`, with these changes:
  - Drop the `source` column on every table (one source = no need)
  - Update column COMMENTs to remove all "JB: X | BR: Y" forking — describe the single canonical resolution
  - Add `is_starter` BOOLEAN to `player_box_basic`
  - Switch `minutes_played` from INT to FLOAT/NUMERIC for MM:SS precision
  - Add the new "wanted" columns to existing tables (attendance, arena, series_label on `games`; shoots, birth_city on `players`)
- Add DDL for new tables: `standings`, `awards`, `all_stars`, `all_nba_teams`, `season_leaders`, `coaches`
- Build `historical_backfill.py` orchestrator:
  - Walks every NBA season from 1946 forward
  - Checkpoints to `ZK_NBA_V2.RAW.backfill_progress` (so 6h GHA limit doesn't lose state)
  - Calls existing `_settle_game()` per game (after adapting it to write to V2)
- Add a `.github/workflows/historical_backfill.yml` workflow with `workflow_dispatch` inputs for season-range

### Phase 3 — Scrape backfill (~3-7 days wall time, ~0 effort once started)

**Goal**: populate `ZK_NBA_V2` with everything from BR.

- Spawn parallel GHA workflows by decade chunks (1946-1959, 1960s, 1970s, 1980s, 1990s, 2000s, 2010s, 2020s).
- Each chunk ~5-7 hours of crawling (well under GHA's 6h limit if we checkpoint).
- Monitor via `gh run list`; re-run any failures.
- Scrape new tables: standings (80 pages), awards (80 pages), all_stars (80 pages), all_nba (1 page), season_leaders (80 pages), coaches (~400 coaches × 1 page). Total ~700 pages × 3s = ~35 min.
- Player bios: ~6,500 player pages × 3s = ~5.5 hours (one-shot).
- Team-season pages (per-coach, per-record): ~30 × 80 = 2,400 pages × 3s = ~2 hours.
- Play-by-play: defer to Phase 3.5 if it doesn't fit. ~2.4M events worth of pages = another ~48 hours of crawling. Maybe limit to 1996+ where coverage is reliable.

### Phase 4 — Parity validation (~1-2 hours)

**Goal**: prove `ZK_NBA_V2` is at least as good as `ZK_NBA` before swap.

- Famous game spot-checks (each should match `ZK_NBA` values within rounding):
  - Wilt's 100-point game (1962-03-02)
  - Jordan's 63 vs Boston (1986-04-20)
  - Kobe's 81 (2006-01-22)
  - Klay's 37-point quarter (2015-01-23)
  - Jokic's most recent Finals game
- Career total spot-checks: LeBron lifetime points, Russell rebounds, Wilt scoring titles
- Row count comparison: `ZK_NBA.player_box_basic` vs `ZK_NBA_V2.player_box_basic` per season
- Document any V2-vs-V1 deltas. Expected: V2 has *more* rows (BR captures some games JB missed; we saw +4,103 for 2024-25 already).

### Phase 5 — Cutover (~30 min, atomic)

**Clean swap. No parallel persistence; once the old is dead it's dead.**

```sql
USE ROLE ACCOUNTADMIN;  -- needed for RENAME at database level
DROP DATABASE ZK_NBA;             -- gone
ALTER DATABASE ZK_NBA_V2 RENAME TO ZK_NBA;
```

- Same Snowflake account, role, warehouse, DB name post-rename. **No GHA secret changes needed.**
- Update `daily_settle.py` only if it was hardcoded to `ZK_NBA_V2` during Phase 2; otherwise it just continues against the renamed DB.
- Restart daily cron (it'll fire next at 8:30 UTC).

### Phase 6 — Cleanup (~1-2 hours)

- Delete `sql/050_seed_from_jb/` directory entirely
- Delete `sql/060_xref_setup.sql` JB-seeding step (xref tables now populated by resolvers directly)
- Drop `JB_HISTORIC_NBA` references from `docs/SETUP.md` and `README.md`
- Delete `dev/_backfill_br_*.sql` (no longer relevant)
- Delete `dev/_dedup_player_box.sql` (no longer relevant)
- Simplify `daily_settle.py`'s `_resolve_team_ids_for_game()` — drop the `WHERE source = 'br_scrape'` filter (everything's BR now)
- Update `HANDOFF.md` with a "rebuild complete" entry; preserve the data-quality audit section as historical context
- Update all table-level COMMENTs to remove "Source boundary" language (one source, one semantic)

---

## Cutover model

**No parallel persistence.** Once `ZK_NBA_V2` is validated and renamed, the old `ZK_NBA` is dropped immediately. No 30-day grace. No backup. Snowflake time-travel (default 1 day) provides emergency rollback if Phase 5 reveals a parity issue we missed.

Same Snowflake account, role (`DEVELOPER_ADMIN`), warehouse (`NBA_INGEST_WH`), final database name (`ZK_NBA`). GHA secrets unchanged. Daily cron picks up where it left off.

---

## Open questions for the next agent

1. **Pre-1976 coverage**: does BR have per-player boxscores back to 1946-47, or only totals? Validated in Phase 1. If only totals, decide whether to keep JB for pre-1976 (compromise) or accept the loss.
2. **Play-by-play scope**: include in Phase 3 (extends scrape time by ~48h) or defer to a Phase 7 follow-up? My recommendation: defer. PBP isn't required for the friend's core queries.
3. **Shot chart data**: BR has shot-location data on separate `/boxscores/shot-chart/{slug}.html` pages. Highly valuable but means a third fetch per game. Recommendation: defer to follow-up.
4. **player_id strategy**: BR slug as canonical, or NBA Stats API ID (resolved via BR player page's stats.nba.com external link)? My recommendation: keep the NBA Stats API ID strategy we built. It's already working, and gives us future cross-source compatibility if we ever want to join other NBA-Stats-derived datasets.
5. **draft_combine source**: BR doesn't have a great draft-combine page; the NBA Draft Combine page on nba.com has it but NBA.com is off-limits (TOS). Recommendation: skip draft_combine in the rebuild. We lose ~1,200 rows of measurements; the friend probably doesn't care.
6. **Cron behavior during scrape**: should daily_settle continue writing to old `ZK_NBA` during the Phase 3 scrape, or pause? Recommendation: keep writing to `ZK_NBA`. The Phase 3 backfill writes everything fresh to `ZK_NBA_V2` from BR including last-night's games, so the parallel daily writes to the old DB are throwaway.

---

## Reusable assets from this session (don't rewrite these)

- `src/nba_ingest/fetchers/boxscore.py` — works for any game (1946+)
- `src/nba_ingest/fetchers/games.py` — date-index scraping
- `src/nba_ingest/flatteners/boxscore.py` — handles all output tables
- `src/nba_ingest/resolvers/player_id.py` — 3-tier player resolution (cache → name → external link)
- `src/nba_ingest/resolvers/official_id.py` — 2-tier official resolution
- `daily_settle.py` MERGE constants + `_resolve_team_ids_for_game()` — write path
- `sql/070_derived_views/001_vw_team_box.sql` — works on any source

The new code is just the historical orchestrator. Everything else is plumbing we already have.

---

## Estimated total effort

| Phase | Code | Wall time |
|---|---|---|
| 1. Validation | 0 | 1-2 hours focused |
| 2. Setup | ~3 hours | ~3 hours |
| 3. Scrape | 0 | 3-7 days background |
| 4. Validate | ~1 hour | ~2 hours focused |
| 5. Cutover | ~30 min | ~30 min |
| 6. Cleanup | ~1 hour | ~1-2 hours focused |
| **Total** | **~5-6 hours** | **~1.5 weeks calendar** |

Most of that wall-time is unattended GHA scrape runs. Active focused time is roughly a long working day.
