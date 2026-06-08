# Rebuild Plan: Pure Basketball-Reference Architecture

**Status**: Approved 2026-05-19. **Phase 0 in progress as of 2026-05-20** — see `docs/BR_DATA_CATALOG.md` for the underlying evidence. The data-inventory section below has been updated with rows marked **"(Phase 0 verified)"** or **"(Phase 0 revised)"** wherever exploration fetches changed the picture; rows without those markers are still hypothesized.

> **How we work + why the hard design calls went the way they did: see [`REBUILD_METHOD.md`](REBUILD_METHOD.md)** — the teleological/test-first per-phase contract, the basketball-domain ontology audit (where else the FINALS-class gap shows up), the evolving-data-availability architecture (the `metric_coverage` registry + no-ambiguous-NULL invariant), and the scrape bad-data guard.

---

## Why we're rebuilding

The current architecture mixes two sources — `JB_HISTORIC_NBA` (seeded from NBA Stats API) and Basketball-Reference (scraped) — with an explicit boundary at 2023-06-12. The session log in `HANDOFF.md` documents a long chain of bugs that all trace back to the *interaction* between sources (two `game_id` formats, encoding splits, table-cutoff inconsistencies inside JB itself, TRUNCATE-as-collateral-damage, the team_id resolver complexity). None of those bugs would exist in a single-source pipeline.

The current state is shippable, but every future change pays interest on the seam. We're choosing to pay the rebuild cost once instead of the friction tax forever.

Today's session was load-bearing for the rebuild: the BR fetchers, flatteners, player_id resolver, team-abbr translation, and post-MERGE resolution pattern are all reusable. We're not starting over — we're starting from a much more informed position.

---

## Architectural principles (carried forward from today's learnings)

These principles emerged from this session and should shape every rebuild decision:

1. **Single source per logical entity.** No mixed-source FLAT tables; no per-row `source` column needed because there's only one source.
2. **Explicit boundary documentation.** When BR genuinely lacks data for an era (e.g., per-quarter splits pre-modern era, play-by-play pre-1996, `attendance` pre-1955), document the era cleanly in column COMMENTs — not in agent-facing footnotes. *Note: the original example "advanced stats pre-2001" was disproven by Phase 0 — see `BR_DATA_CATALOG.md`. The boundary for the advanced player box is ≤1985, not 2001.*
3. **Canonical entity resolution at write time.** Player_id, team_id, official_id all resolved during MERGE, not as post-hoc backfills. The resolvers we already built stay.
4. **MERGE everywhere; no TRUNCATE.** All writes are idempotent. Re-running on already-settled data is a no-op semantically.
5. **Schema metadata is load-bearing.** Column COMMENTs are read by the LLM agent at query time — every column gets an accurate, source-traceable comment.
6. **Empty tables are deleted, not documented.** If a loader isn't built yet, the table doesn't exist yet. No "WIP" tables.
7. **Audit before adding.** Verify column population, not just column existence, before scoping enrichment work. (The phantom Gap 1 lesson.)
8. **Verify reserved words upfront.** `rows` bit us four times today; pre-check Snowflake reserved-word lists when writing throwaway audit SQL.

---

## Methodology: vertical slices + reflection gates

Progress as a series of **thin vertical slices**, each one a working end-to-end pipeline at a different scope. Every slice produces queryable data and gets validated against expectations before the next slice expands scope. We pivot freely if a slice reveals the plan was wrong — that's the point of slicing.

After every phase, a **reflection gate** asks three questions:

1. **What did we actually do?** Concrete record of the implementation — what files changed, what data landed, what got skipped.
2. **Why did we do it that way?** Decision log — what alternatives were considered, what constraints drove the call.
3. **Do findings jive with the plan?** Reality check — what was easier than expected, what was harder, what assumptions broke. Update the next phase's scope accordingly.

Reflection gate output gets appended as a dated section to this doc (e.g., `## Phase 1 Reflection — YYYY-MM-DD`). That keeps the rebuild's own decision history in one place — the same load-bearing-history pattern that makes `HANDOFF.md` useful for the current state.

**Anti-patterns we're avoiding** (drawn from this session's experience):
- "Build it all then validate" — bugs surface late, expensive to fix
- "Validate by reading code" — code doesn't reveal data-quality issues; only running queries does
- "Skip the retro" — every painful surprise this session could have been caught earlier with a 10-minute "does this make sense?" gate

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
| ts_pct, efg_pct, fg3a_rate, fta_rate, orb_pct, drb_pct, trb_pct, ast_pct, stl_pct, blk_pct, tov_pct, usg_pct, ortg, drtg, bpm | ✓ (2023+ only) | high | **(Phase 0 revised)** advanced-box table present back to at least 1985 — revised from "back to 2001". Column-level population pre-2001 is **still TBD**: some metrics (bpm, ortg, drtg) require opponent-context computations that may have always been NULL in the early eras. Verify by inspecting 1985 G6's `box-LAL-game-advanced` row contents. |

**Improvements over current state**: store `minutes_played` as decimal (e.g. 36.13 for 36:08) instead of rounded INT — fixes the team-minutes sanity-check mismatch. Add `is_starter` for bench-stat queries.

### Player-quarter / player-half grain — NEW (Phase 0 surfaced 2026-05-20)

BR exposes per-quarter and per-half player boxscores as separate visible tables on each boxscore page. Neither was in the original data inventory. Confirmed by 2010 G7 and 2024 SAS@MEM fetches; absent in 1995 G4 fetch. Boundary unpinned (catalog action item).

| Field | Have today? | Value | BR availability |
|---|---|---|---|
| `box-{TTT}-q1-basic` … `q4-basic` (per-quarter player box: min/pts/ast/reb/etc.) | ✗ | medium — "best 4th-quarter scorers", verifies Phase 5 spot-check (Klay's 37-pt quarter) directly | **(Phase 0 verified)** present in 2010+ and 2024 fetches; **absent in 1995**. Boundary between 1995 and 2010 unpinned — see catalog task #8. |
| `box-{TTT}-h1-basic`, `h2-basic` (per-half player box) | ✗ | low — derivable from quarters but BR pre-computes | same boundary as per-quarter. |

**Scope decision deferred to Phase 0 reflection gate**: should `player_quarter_box` and `player_half_box` be new tables in `ZK_NBA_V2`? Tradeoff: cheap to flatten alongside the game box (already in HTML), but ~5x bloats the player-level row count (~ player-game × 6 grain).

### Game grain (`games`, `line_scores`)

| Field | Have today? | Value | BR availability |
|---|---|---|---|
| game_id, game_date, season, season_id, season_type | ✓ | core | yes (derive season_type from game_id pattern) |
| home/away_team_id, abbr, pts, wl | ✓ | core | yes |
| home/away aggregates (fgm/fga/.../plus_minus) | ✓ | core | yes |
| q1-q4 + ot1-ot4 per side | ✓ | core | yes (hidden line_score table) |
| **attendance** | ✗ | medium | **(Phase 0 verified)** yes from 1955+; ~100% NULL for the ~1947-1954 BAA era (first BAA game 1946-11-01 has no `<strong>Attendance:</strong>` block at all). Format: `<strong>Attendance:&nbsp;</strong>16,108` (note `&nbsp;` separator, not whitespace — HTML-decode before regex). |
| **arena_name** (per-game) | ✗ | medium | **(Phase 0 revised — UNVERIFIED)** the literal `<strong>Arena:</strong>` label did not match in any sampled era (1947, 1955, 1965, 1975, 1985, 1995, 2010, 2024). Either BR uses a different DOM construct or this data isn't actually exposed on the boxscore page. **Investigation required before committing** — see `BR_DATA_CATALOG.md` task #9. May need to drop this column from rebuild scope. |
| **start_time** (local TZ) | ✗ | low | **(Phase 0 not verified)** assume meta block; inspect DOM first. Time of Game (game duration) is confirmed at 1985+ as `<strong>Time of Game:&nbsp;</strong>2:24` but that's duration, not tipoff time. |
| **broadcast_network** (TNT, ESPN, ABC, etc.) | ✗ | medium — for "show me TNT Thursday games" queries | **(Phase 0 revised — UNVERIFIED)** `<strong>TV:</strong>` did not match in any sampled era. Same investigation as `arena_name`. May need to drop from rebuild scope. |
| **series_label** ("NBA Finals - Game 5", "Eastern Conference Finals - Game 3") | ✗ | high — playoff context | **(Phase 0 not verified)** my naive `<h2>...Game N...</h2>` regex didn't match on the 1995 / 2010 Finals fetches. The label may live in a different DOM element (page `<h1>`, breadcrumb, etc.). Inspect a playoff page's DOM before committing. |
| **game_label** ("Christmas Day Game", "Opening Night") | ✗ | low | **(Phase 0 not verified)** inspect a special-game page meta (e.g., 2024 Christmas Day game) before committing. |

**Phase 0 footnote on game-grain meta blocks** (2026-05-20): only **`attendance`** and **`time_of_game`** were positively located across the 8 era fetches. The other four enrichment columns are unverified — and three are *negatively* unverified (the expected `<strong>LABEL:</strong>` patterns did not appear). Before Phase 1 commits these columns to the V2 DDL, the catalog's "Locate arena_name and broadcast_network in raw HTML" action item must resolve where (if anywhere) they actually live in BR's HTML.

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

Each phase ends with a **reflection gate** — append a dated section to this doc capturing (1) what we actually did, (2) why, (3) what findings changed our next-phase scope. Pivot freely.

### Phase 0 — BR exploration (1-2 sessions, no scraping commitment)

**Goal**: catalog what BR actually exposes, beyond the page types we already know. This is wide-and-shallow research before we commit to any schema or scope.

Deliverable: a new `docs/BR_DATA_CATALOG.md` document. The data-inventory section above tells us what we *want*; the catalog tells us what BR *has* and informs us about things we didn't know to want.

Tasks:
- **Inventory every BR page type** by walking the site map: boxscore, player, team-season, franchise, coach, official (referee), schedule, leagues, awards, all-star, all-NBA, draft, standings, leaders, transactions, playoffs bracket, shot charts, play-by-play. For each: URL pattern, HTML structure (visible tables, hidden-comment tables, meta blocks), data fields, era coverage.
- **Era sample fetches** — pull one game and one player per era and document era-specific gaps:
  - 1947 (BAA founding year)
  - 1955 (post BAA-NBA merger)
  - 1965 (pre-shot-clock-fully-adopted)
  - 1975 (ABA era)
  - 1985 (3-point line introduced)
  - 1995 (modern stats era starts)
  - 2010 (advanced stats fully tracked)
  - 2024 (current)
- **Cross-page navigation map** — how do BR pages link to each other? E.g., boxscore → player page → external `stats.nba.com` link (drives the player_id resolver). Document the link graph so the next agent knows the resolver patterns.
- **Surprise inventory** — things BR has that REBUILD_PLAN.md's data inventory didn't mention. Examples to watch for: salary history pages, contract data, college career stats per player, international career stats, draft-prospect pages (pre-draft), referee crew assignments, scoring-distribution tables (by quarter/half).
- **Rate-limiting reality check** — confirm BR's `robots.txt` is still 3s crawl-delay (or revised), confirm we won't hit any IP-based bans during sustained scrape. Maybe do a 10-minute sustained-fetch test to estimate real throughput vs. the theoretical 3s/page.

**Reflection gate ✋**
- Update the data inventory above with anything Phase 0 surfaced.
- Decide which "new tables" (standings, awards, etc.) are confirmed-included vs. deferred to a Phase 7 follow-up.
- Decide pre-1976 coverage: does BR have enough per-player data to use as the sole source, or do we keep JB as fallback for the very-old era?
- Update Phase 1's slice definition based on what we learned.

---

## Phase 0 Reflection — 2026-06-08

Phase 0's telos: *catalog what BR actually exposes before committing any schema, so Phase 1 builds on evidence, not assumption.* Closeout done per `REBUILD_METHOD.md` contract.

### Run the test (definition of success: every empirical question Phase 1 depends on is answered with a real fetch)

| Question | Result |
|---|---|
| Where does BR encode the **playoff round/series** (the FINALS gap)? | **Answered.** Boxscore `<h1>`/`<title>` (`"2023 NBA Finals Game 5"`) + bracket page `/playoffs/NBA_{year}.html` round-encoded series slugs. Round becomes first-class. |
| Can we infer **stat-availability** from BR's columns? | **Answered — no.** Column template is uniform across eras; 1972-73 shows `STL/BLK/TOV` headers with all-`NaN` cells. Availability = cell population + domain breakpoints (STL/BLK/ORB 1973-74, TOV 1977-78, 3P 1979-80). |
| `arena_name` / `broadcast_network`? | **Answered.** Arena is in `scorebox_meta` (pipe segment); broadcast network is absent → dropped. |
| Advanced-box era + population? | **Answered.** Tables and `TS%/USG%/ORtg/DRtg/BPM` populated back to ≥1985. |
| Per-quarter boundary? | **Answered.** ≤2001 (present 2001 & 2005, absent 1995). |
| Crawl-delay? | **Answered.** `robots.txt` = 3s, matches the client. |

**Not exhaustively done (deliberate):** §1.3 breadth inventory of secondary page types (awards, standings, draft, coaches). These feed the "new tables" decision, which is a later slice — cataloging them now would be exploring pages we won't build against for a while. Decision: **catalog them just-in-time** when their slice arrives, not as a Phase 1 blocker.

### Reflect against goals and values

- **Single source** held up: BR has per-player basic boxscores back to the first BAA game (1946-11-01), so we never need a second source. The whole V1 bug class is designed out.
- **Ontology-grounding earned its keep:** the stat-availability trap (finding B) is invisible to pure data inspection — only basketball knowledge (when the NBA started tracking each stat) reveals it. Exactly the "don't model data for data's sake" value. We'd have shipped "Russell: 0 steals" without it.
- **Fail-loud** now has a concrete first target: blank pre-tracking cells must never coerce to 0.
- No walls required a values-diverging pivot.

### Favors for future-us

- `metric_coverage` methodology pinned down (author from domain breakpoints, verify against cells — never auto-derive). The biggest favor.
- Round/series sourcing decided and documented, so Phase 1 can implement the FINALS fix directly.
- Corrected a false negative (arena "never" → it's in `scorebox_meta`), saving the next person a wrong scoping call.

### Reflection-gate decisions

1. **Data-inventory updates:** advanced ≥1985 (done); `arena_name` → **include** (scorebox_meta); `broadcast_network` → **drop**; **add** a `round`/`series` dimension (`playoff_series` table + `games.round`, `games.game_in_series`); **add** `metric_coverage`; `player_quarter_box` → **include** as a 2001+ table; `minutes_played` → decimal; `is_starter` → derive from row position vs. the "Reserves" separator.
2. **New tables — include vs defer:** Phase 1 = **core only** (`games`, `player_box_basic`, `player_box_advanced`, `line_scores`, `players`, `teams`) **+ round/series + `metric_coverage`**. Everything deferred goes to the **[Deferred backlog](#deferred-backlog-tracked)** with a trigger — `standings`/`awards`/`all_stars`/`all_nba`/`season_leaders`/`coaches` (cheap, ~1 page/season, not needed for the core goal), shot-charts + PBP, and just-in-time §1.3 cataloging. No item is deferred without a backlog row.
3. **Pre-1976 coverage:** **BR-only, no JB fallback.** Confirmed BR coverage to 1946; single-source is the point. Thin old-era coverage is documented honestly via `metric_coverage`, not patched with a second source.
4. **Phase 1 scope:** unchanged slice (2024-25 Denver Nuggets, ~95 games incl. their 2025 playoff run) — but the **test must assert correct `round` tagging on their 2025 playoff series**, the basketball-truth check that the current DB fails.

> ✋ **Gate: paused for sign-off.** No Snowflake writes until these decisions are approved and the Phase 1 charter is agreed (per chosen cadence).

---

### Phase 1 — Vertical slice: one team, one recent season (~1 session, ~3-4 hours)

**Goal**: prove the end-to-end pipeline works on a narrow, contained scope. Build the minimum viable plumbing for ONE team's ONE recent season — everything from fetch to query.

Slice: **2024-25 Denver Nuggets** (~95 games incl. playoffs). Recent so coverage is robust; one team so we're not gated on volume.

Tasks:
- Create `ZK_NBA_V2` database + the minimum required schema: `games`, `player_box_basic`, `player_box_advanced`, `line_scores`, `players`, `teams`. (Skip game_officials, game_inactives, draft, pbp for this slice — add in later slices.)
- DDL changes from V1: drop `source` columns; add `is_starter` BOOLEAN to `player_box_basic`; switch `minutes_played` to decimal; add `attendance` to `games` (Phase 0 verified). **Defer `arena_name`, `series_label`, `broadcast_network`** until Phase 0's catalog action item locates their DOM source — Phase 0 regex did not find the expected `<strong>Arena:</strong>` / `<strong>TV:</strong>` labels in any sampled era. Adding columns we can't populate would just create NULL noise.
- Build the minimum-viable backfill orchestrator: hardcode "Denver Nuggets, 2024-25 season" and walk the team-season page to enumerate game slugs.
- Reuse `daily_settle.py`'s fetch/flatten/MERGE pipeline. Adapt for V2 schema.
- Run the slice. ~95 games × 3s = ~5 minutes of crawling.
- Validate: query `vw_team_box`, query Jokic's season, join player_box to games. Does it all work? Does the data look right?

**Reflection gate ✋**
- Did the V2 schema design hold up? Any column added in Phase 0 that turned out to be wrong shape?
- Was `is_starter` extractable? `minutes_played` as decimal? Or did we lose precision?
- Did the BR fetch behave as expected, or were there surprises?
- What schema changes are needed before expanding scope?

---

### Phase 2 — Vertical slice: full recent season, all teams (~1 session, ~5-6 hours)

**Goal**: test throughput, schema robustness across teams, and the orchestrator's stamina. Generalize from one team to thirty.

Slice: **all 30 teams, 2024-25 season** (~1,316 games incl. playoffs).

Tasks:
- Generalize the orchestrator to walk all teams' season pages OR walk the date-index pages (the latter avoids team-page duplication — every game has two team-page entries).
- Add checkpointing to `ZK_NBA_V2.RAW.backfill_progress` so a 6h GHA limit doesn't reset progress.
- Add the remaining per-game tables: `game_officials`, `game_inactives`. Same DDL adjustments as Phase 1.
- Run on a GHA workflow (estimate: 1,316 × 3s = ~1.1 hours scrape, comfortably under 6h).
- Validate: full season parity vs current `ZK_NBA.player_box_basic` for season=2025. Row counts should match within tolerance.

**Reflection gate ✋**
- Did GHA's 6h limit get close? If yes, more aggressive checkpointing for Phase 3.
- Did parallel team-page fetches cause rate-limiting? (We shouldn't be doing parallel; sanity-check the orchestrator's serial behavior.)
- Any per-team data oddities (relocated teams, mid-season team changes)?
- Schema still right after a full season's worth of data?

---

### Phase 3 — Vertical slice: one historical decade (~1 session + GHA wall time)

**Goal**: stress-test era handling. Modern data is easy; old data is where assumptions break.

Slice: **the 1970s** (1969-70 through 1978-79). 10 seasons, ~10,000 games. Diverse: ABA-era oddities, pre-3-point-line stats, less complete advanced data, franchise relocations.

Tasks:
- Run the orchestrator over 10 seasons. ~10K games × 3s = ~8 hours; split into two GHA workflow runs (e.g. 1970-74 + 1975-79).
- Add `team_history` JOIN logic if relocated franchises need special handling.
- Add `draft` table population (BR draft pages for these years).
- Spot-check: famous old games (Wilt's 100 was 1962, just outside; pick Kareem-era games like the 1970-71 Bucks championship run).

**Reflection gate ✋**
- Did pre-3pt-line games' `fg3_pct` columns NULL out correctly (no 3-pointers existed)?
- Did `is_starter` work for old games where BR's table format may differ?
- Did `attendance` show up for old games?
- Were there franchise-name complications (Cincinnati Royals → Kansas City Kings, etc.)?
- Anything else era-specific that breaks assumptions?

---

### Phase 4 — Full historical backfill (~3-5 days wall time, ~0 active effort)

**Goal**: populate everything else.

Tasks:
- Run remaining decades in parallel GHA workflows: 1946-1959, 1960s, 1980s, 1990s, 2000s, 2010s, 2020s.
- Run the additional-table scrapes (the "new tables" from data inventory): standings (~80 pages), awards (~80 pages), all_stars (~80 pages), season_leaders (~80 pages), coaches (~400 pages), franchise pages (~30 pages). Total ~700 pages × 3s = ~35 min.
- Run player bios scrape (~6,500 pages × 3s = ~5.5 hours).
- Defer play-by-play to Phase 7 unless Phase 0 said otherwise.

**Reflection gate ✋**
- Were any decades different from the 1970s template in Phase 3? What surprised?
- Did any GHA runs fail? What was the failure mode? Re-run cleanly?
- Row counts per era as expected?

---

### Phase 5 — Parity validation (~1 session, ~2 hours)

**Goal**: prove `ZK_NBA_V2` is at least as good as `ZK_NBA` before swap.

Tasks:
- Famous game spot-checks (each should match `ZK_NBA` values within rounding):
  - Wilt's 100-point game (1962-03-02)
  - Jordan's 63 vs Boston (1986-04-20)
  - Kobe's 81 (2006-01-22)
  - Klay's 37-point quarter (2015-01-23)
  - Jokic's most recent Finals game
- Career total spot-checks: LeBron lifetime points, Russell rebounds, Wilt scoring titles
- Row count comparison: `ZK_NBA.player_box_basic` vs `ZK_NBA_V2.player_box_basic` per season
- Spot-check the new tables (standings, awards) against known facts (1996 Bulls 72 wins; 1962 MVP was Russell)
- Document any V2-vs-V1 deltas. Expected: V2 has *more* rows (BR captures some games JB missed; we saw +4,103 for 2024-25 already).

**Reflection gate ✋**
- Any spot checks that don't match? Bug or expected? (Sometimes BR's values legitimately differ from NBA Stats API by a few decimal places.)
- Is V2 *worse* than V1 on any dimension? If yes, must be addressed before cutover.

---

### Phase 6 — Cutover (~30 min, atomic)

**Clean swap. No parallel persistence; once the old is dead it's dead.**

```sql
USE ROLE ACCOUNTADMIN;  -- needed for RENAME at database level
DROP DATABASE ZK_NBA;             -- gone
ALTER DATABASE ZK_NBA_V2 RENAME TO ZK_NBA;
```

- Same Snowflake account, role, warehouse, DB name post-rename. **No GHA secret changes needed.**
- Update `daily_settle.py` only if it was hardcoded to `ZK_NBA_V2` during Phase 1; otherwise it just continues against the renamed DB.
- Restart daily cron (it'll fire next at 8:30 UTC).

**Reflection gate ✋**
- First post-cutover cron run: did it succeed? Was the data clean?
- Any agent queries that now fail that worked before? Investigate immediately (within Snowflake time-travel window).

---

### Phase 7 — Cleanup + deferred enrichments (~1-2 hours active + optional follow-ups)

Hard cleanup (active, do these immediately after cutover):
- Delete `sql/050_seed_from_jb/` directory entirely
- Delete `sql/060_xref_setup.sql` JB-seeding step (xref tables now populated by resolvers directly)
- Drop `JB_HISTORIC_NBA` references from `docs/SETUP.md` and `README.md`
- Delete `dev/_backfill_br_*.sql` (no longer relevant)
- Delete `dev/_dedup_player_box.sql` (no longer relevant)
- Simplify `daily_settle.py`'s `_resolve_team_ids_for_game()` — drop the `WHERE source = 'br_scrape'` filter (everything's BR now)
- Update `HANDOFF.md` with a "rebuild complete" entry; preserve the data-quality audit section as historical context
- Update all table-level COMMENTs to remove "Source boundary" language (one source, one semantic)

Deferred enrichments: **worklist is the [Deferred backlog](#deferred-backlog-tracked)** — pull rows whose trigger has fired (play-by-play, shot charts, coaches, awards/standings/leaders, salary, college stats, etc.). Do not maintain a separate list here.

**Reflection gate ✋ (the meta-retro)**
- What were the biggest surprises of the rebuild? Update the architectural principles section above.
- What's the next bottleneck? Plan the next initiative.

---

## Deferred backlog (tracked)

Single source of truth for everything we consciously *chose not to build yet*. A deferral is only legitimate if it lands here with a **trigger** — the concrete condition that pulls it back in. Nothing gets "deferred to Phase 7" in the abstract; it gets a row. When an item is built, mark it Done with the commit/phase, don't delete it (the record is the favor-to-future-us).

| Item | Grain / source | Why deferred | Trigger to pull in | Status |
|---|---|---|---|---|
| `standings` table | (season, team) · `/leagues/NBA_{year}_standings.html` | Not needed for core box-score / Finals goal | "best team ever" / seed / conference-rank queries, or the recent-season aux-tables slice | Deferred |
| `awards` table | (season, award) · `/awards/awards_{year}.html` | Narrative-only; derivable later | MVP / ROY / DPOY queries | Deferred |
| `all_stars` table | (season, player) · `/allstar/NBA_{year}.html` | Narrative-only | "most All-Star selections" queries | Deferred |
| `all_nba_teams` table | (season, tier, player) · `/awards/all_league.html` | Narrative-only | All-NBA / All-Defense queries | Deferred |
| `season_leaders` table | (season, cat, rank, player) · `/leagues/NBA_{year}_leaders.html` | Derivable from box via window funcs | "scoring titles" / per-cat leader queries | Deferred |
| `coaches` table | (coach, season, team) · `/coaches/{slug}.html` | Not in core grain | coach-career / "winningest coach" queries | Deferred |
| Shot charts | per-shot x/y/distance/zone · `/boxscores/shot-chart/{slug}.html` | +1 fetch/game; high value but heavy | Phase 7, or heat-map / shot-zone queries | Deferred |
| Play-by-play | event · `/boxscores/pbp/{slug}.html` | +~48h scrape; not needed for core | Phase 7 | Deferred |
| §1.3 breadth page cataloging | n/a (catalog work) | Exploring pages we won't build against yet | **Just-in-time**: when the owning table's slice above is triggered | Deferred |
| `inactive_reason` (injury/rest/G-League) | player-game · inactive meta | DNP-semantics ontology (method §5); not core | when modeling DNP / load-management queries | Deferred |
| Player-bio enrichments (`shoots`, `hall_of_fame_year`, birth granularity) | player · player page | Not core; HoF is the high-value one | "HoFers' rookie seasons" / lefty-leader queries | Deferred |
| Salary history | (player, season, team) · player page | Out of core scope; verify BR exposes cleanly | salary / contract queries | Deferred |
| College career stats | (player, season) · player page | Out of core scope | pre-NBA / draft-prospect queries | Deferred |

> Phase 7 ("Cleanup + deferred enrichments") draws its worklist from this table — it is not a separate list. If you prefer external tracking, these rows map 1:1 to GitHub issues; say the word and I'll file them.

---

## Cutover model

**No parallel persistence.** Once `ZK_NBA_V2` is validated and renamed, the old `ZK_NBA` is dropped immediately. No 30-day grace. No backup. Snowflake time-travel (default 1 day) provides emergency rollback if Phase 5 reveals a parity issue we missed.

Same Snowflake account, role (`DEVELOPER_ADMIN`), warehouse (`NBA_INGEST_WH`), final database name (`ZK_NBA`). GHA secrets unchanged. Daily cron picks up where it left off.

---

## Reflection gate template

Copy-paste this template at the end of each phase. Append, don't overwrite — accumulating retros is the value.

```markdown
## Phase N Reflection — YYYY-MM-DD

### What did we actually do?
- Files changed: ...
- Data landed: ... (row counts, tables touched)
- Skipped from plan: ...
- Added beyond plan: ...

### Why did we do it that way?
- Decisions made and rationale: ...
- Alternatives considered: ...
- Constraints that drove choices: ...

### Do findings jive with the plan?
- Assumptions that held: ...
- Assumptions that broke: ...
- Surprises (good and bad): ...

### Updates to the rest of the plan
- Phase N+1 scope adjustments: ...
- Data inventory updates: ...
- Principle additions/refinements: ...
```

---

## Open questions for the next agent

1. ~~**Pre-1976 coverage**: does BR have per-player boxscores back to 1946-47, or only totals?~~ **Resolved by Phase 0 (2026-05-20)**: BR has per-player basic boxscores back to the first BAA game (1946-11-01 NYK @ TRH returned two visible tables: `box-NYK-game-basic` and `box-TRH-game-basic`). No need to keep JB as a fallback for the very-old era. Open follow-up: confirm column-level completeness (min, pts, fgm, etc.) on the 1947 row — pre-shot-clock pre-3pt era — before Phase 1 schema commits.
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

| Phase | Active code/SQL | Wall time | Output |
|---|---|---|---|
| 0. BR exploration | ~30 min light scraping | 1-2 sessions focused | `docs/BR_DATA_CATALOG.md` + updated inventory |
| 1. Vertical slice: 1 team / 1 season | ~3 hours | ~3-4 hours focused | Queryable Nuggets 2024-25 in ZK_NBA_V2 |
| 2. Vertical slice: full season | ~2 hours | ~5-6 hours (incl. ~1.1h scrape) | All teams 2024-25 in V2 |
| 3. Vertical slice: 1 decade | ~1 hour | ~10 hours (incl. ~8h scrape, split into 2 GHA runs) | 1970s in V2 |
| 4. Full backfill | 0 | 3-5 days background | Everything in V2 |
| 5. Parity validation | ~1 hour | ~2 hours focused | Pre-cutover go/no-go |
| 6. Cutover | ~30 min | ~30 min | V2 renamed to ZK_NBA; legacy dropped |
| 7. Cleanup + deferred enrichments | ~1-2 hours | ~1-2 hours focused | JB references purged; optional follow-ups identified |
| **Total** | **~8-10 hours active** | **~2 weeks calendar** | |

Active focused time is ~1.5 working days spread across 5-6 sessions. Most wall-time is unattended GHA scrape runs. **Each phase ends with a reflection gate** — the rebuild's success depends on actually doing these gates, not skipping them in the name of speed.
