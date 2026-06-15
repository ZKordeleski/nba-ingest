# Rebuild Plan: Pure Basketball-Reference Architecture

**Status**: Approved 2026-05-19. **Phase 0 in progress as of 2026-05-20** — see `docs/BR_DATA_CATALOG.md` for the underlying evidence. The data-inventory section below has been updated with rows marked **"(Phase 0 verified)"** or **"(Phase 0 revised)"** wherever exploration fetches changed the picture; rows without those markers are still hypothesized.

> **How we work + why the hard design calls went the way they did: see [`REBUILD_METHOD.md`](REBUILD_METHOD.md)** — the teleological/test-first per-phase contract, the basketball-domain ontology audit (where else the FINALS-class gap shows up), the evolving-data-availability architecture (the `metric_coverage` registry + no-ambiguous-NULL invariant), and the scrape bad-data guard.

---

## Why we're rebuilding

The current architecture mixes two sources — `JB_HISTORIC_NBA` (seeded from NBA Stats API) and Basketball-Reference (scraped) — with an explicit boundary at 2023-06-12. The session log in `HANDOFF.md` documents a long chain of bugs that all trace back to the *interaction* between sources (two `game_id` formats, encoding splits, table-cutoff inconsistencies inside JB itself, TRUNCATE-as-collateral-damage, the team_id resolver complexity). None of those bugs would exist in a single-source pipeline.

The current state is shippable, but every future change pays interest on the seam. We're choosing to pay the rebuild cost once instead of the friction tax forever.

Today's session was load-bearing for the rebuild: the BR fetchers, flatteners, player_id resolver, team-abbr translation, and post-MERGE resolution pattern are all reusable. We're not starting over — we're starting from a much more informed position.

---

## V1 source-mash post-mortem: the NBA Finals miss (2026-06-05)

A user asked the agent **"Describe the NBA Finals game this week"** and got nothing — three empty slots and a re-plan loop. Investigation traced every failure mode back to the source seam this rebuild exists to remove. Recording it here as the concrete, *currently-live* evidence behind principle #1 — the strongest case for the rebuild we have.

### The user-visible failure

The 2025-26 Finals games **are in `FLAT.games`** (ingest is current to 2026-06-03), but they're unqueryable: no filter for "the Finals" — or even "the playoffs" — returns a modern game. The agent correctly re-planned, probed `SEASON_TYPE`, and still found nothing, because the data genuinely cannot express the question.

### Three live, measured failure modes — one root cause

All three are the same bug: **a derivation that was correct for the JB seed (NBA-numeric `game_id`, where digit 1 encodes season type: `2`=regular, `4`=playoffs) was applied to BR data (date slugs like `202606030SAS`, where digit 1 is always `2`).** Instead of failing, it produced a confident, plausible, wrong answer.

| Column | State on modern (BR) data | Why | Source |
|---|---|---|---|
| `games.season_type` | **NULL** for all 3,954 BR games | flattener stub, never filled | `flatteners/boxscore.py:568` (`"Slice G can fill from schedule page"`) |
| `games.season_id` | **Wrong** — 100% `2xxxx`, zero playoff `4xxxx` | `LEFT(game_id,1)` is always `'2'` for a slug | `jobs/daily_settle.py:457` |
| `player_box_basic.game_type` | **Wrong** — 104,466 rows all `'Regular Season'` | same `LEFT(game_id,1)` assumption | `jobs/daily_settle.py:487` |
| *(no column)* | No Finals/round dimension exists at all | BR's "Finals - Game N" series label is parsed-adjacent and dropped | `flatteners/boxscore.py:430` keeps only officials/inactives/attendance |

A modern playoff game is therefore *simultaneously* unlabeled (`season_type` NULL), mislabeled regular-season (`season_id` `2xxxx`), and mislabeled regular-season again (`game_type`). Three independent filters all fail.

> **The NULL is the safe failure; the wrong value is the dangerous one.** `season_type` being NULL makes the agent re-plan. `season_id` being a confident `2xxxx` makes it answer *incorrectly* with no signal that anything is off. Rebuild bias: fail loud, never default-plausible.

### It traces to the back-seed — but the residue is *schema-level*, not data-level

The merge is physically clean (verified live): season ≥ 2024 is 100% `br_scrape`, 0 orphaned box rows, 0 NBA-numeric IDs surviving in the BR era. The dedup → recover → `_swap_to_br_canonical` reconciliation worked at the row level.

What the merge left behind is a **fractured column shared across two sources with incompatible semantics:**

- `season_type` carries JB's raw vocabulary untranslated (`050_seed_from_jb/002_games.sql:56` `TRIM(SEASON_TYPE)`) → `'Pre Season'`, and both `'All-Star'` *and* `'All Star'`; BR contributes NULL. The schema COMMENT invents a *third* vocabulary (`Regular Season | Playoffs | Play In | Preseason`) matching neither source.
- `season_id` / `game_type` exist *only* to make BR slugs impersonate JB's NBA-numeric ID format so one column looks uniform. That impersonation is exactly where they break.
- The documented boundary drifted from reality: README/plan say "clean cut at 2023-06-12," but JB box data ran to 2025-04-06 and the real reconciliation was a hand-run `dev/_swap_to_br_canonical.sql` at season ≥ 2024 (incl. recovering 65K rows an earlier dedup over-deleted, via time-travel `AT(OFFSET => -4500)`). The numbered pipeline doesn't reflect what actually happened.

### Secondary findings (same sweep)

- **Draft data stops at 2023** — `MAX(draft.season) = 2023`; the 2024 & 2025 classes were never ingested (`jobs/weekly_meta.py:168,181` are acknowledged stubs). The agent's "Draft Pick" / "Draft Combine" concepts are empty for recent classes.
- `player_box_basic.plus_minus` is NULL for ~18.7% of modern rows (19,484 / 104,466) — a silent partial gap.
- The BR→NBA abbreviation translation (`BRK→BKN`, `CHO→CHA`, `PHO→PHX`) is hardcoded inline in ~4 places in `daily_settle.py` — no single source of truth, the same duplication smell that let the `LEFT(game_id,1)` bug be written wrong in two columns.

### Net for the rebuild

Principle #1 (single source) removes the *root* of all of the above: a pure-BR pipeline has no second ID format to impersonate and no second vocabulary to reconcile. The post-mortem adds four guardrails (principles #9–#12 below) so the *class* of bug can't recur even within a single source.

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
9. **Normalize at ingest; never impersonate another source's encoding.** Each source maps its native fields → a canonical vocabulary/format in its *own* flattener, preserving the raw value alongside for audit. No column is ever derived by making one source mimic another's ID scheme — that's the `LEFT(game_id,1)` anti-pattern from the post-mortem above.
10. **Fail loud, never default-plausible.** A value that can't be sourced is NULL (a *failed mapping*), not a fallthrough default that looks real. A `CASE` derivation gets an explicit unmatched branch that surfaces, not a silent `ELSE` that fabricates a category.
11. **Validate against reality, not self.** Beyond row counts and date ranges, assert distributions that catch confidently-wrong data — e.g., "every recent season has playoff games," "no season's `season_type` is a single degenerate value." All three live bugs in the post-mortem would have tripped such a check on day one.
12. **Reconciliation lives in the numbered pipeline, not dev scripts.** Any dedup / cutover / recovery step is a reproducible, validated pipeline step — so a rebuild can't re-improvise it (or re-introduce the over-delete it caused). `dev/_swap_to_br_canonical.sql` should never have been the canonical record of how the eras were merged.

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

## Phase 1 Reflection — 2026-06-08

Telos: prove the single-source pipeline lands one team-season *truthfully*, including correctly-identified playoff rounds — the thing V1 cannot do.

### Run the test

`sql/v2/090_phase1_test.sql` — **all 14 assertions pass.** Load: 96 games (82 regular + 14 playoff), 2,588 player-box rows, 2,588 advanced, 96 line scores, 15 playoff series, **0 quarantined**.

| | Check | Result |
|---|---|---|
| 1-4 | coverage seeded (17), 82 reg games, 14 playoff games, 2588 box rows | ✓ |
| 5 | all game_id are BR slugs (single-source, no impersonation) | ✓ |
| 6-9 | domain guard on loaded data (no ties, made≤att, fg%∈[0,1], pts∈[0,105]) | ✓ |
| 10 | NULL discipline: modern stl recorded for players who played (0 wrongly-null) | ✓ |
| 11 | **every playoff game carries a canonical round + game_in_series** | ✓ (First Round, Conference Semifinals) |
| 12 | **no playoff game mislabeled Regular Season** (the FINALS-class fix) | ✓ (0 mislabeled) |
| 13 | **Jokić triple-doubles exist** (fan-recognizable truth) | ✓ (37) |
| 14 | team box totals reconcile to player-pts sum | ✓ (0 mismatches) |

The query V1 returned nothing for — *playoff games by round* — now works: First Round G1–G7 (DEN beat LAC 4-3), Conference Semifinals G1–G7 (DEN lost to OKC 4-3), each game tagged with round, game number, matchup, score.

### Reflect against goals and values

- **The headline bug is fixed and proven**, not just asserted: round/series is first-class and sourced from the bracket + boxscore `<h1>`, never from the game_id.
- **Single source held**: every identifier is BR-native (slug/abbr); no second source, no impersonation, no `LEFT(game_id,1)`.
- **The guard worked as a safety net** (0 quarantined this clean modern slice — its real test is the messy historical eras in Phase 3).
- **Test-first paid off**: writing the basketball spot-checks before the build forced the orchestrator to actually source rounds, not just land rows. A row-count-only test would have passed a broken load.
- **Principle #8 caught us once** (the `check` reserved word) — the same class as V1's `rows`. Fixed; reserved-word pre-check stays on the checklist.
- No wall forced a values-diverging pivot.

### Favors for future-us

- `dev/_phase1_slice.py` is the reusable spine for Phase 2 (generalize team enumeration from one team to all 30; add advanced/line already done; add `players`/`teams`/`player_quarter_box` loaders).
- `ZK_NBA_V2.FLAT.quarantine` table exists and is wired — Phase 3's historical eras will exercise it.
- The bracket→series→round mapping is solved and documented in code; Phase 2+ reuse it directly.

### Open for Phase 2 (next gate)

- Generalize enumeration to all 30 teams for 2024-25 (dedupe shared games — each game appears on two teams' pages).
- Add the deferred loaders per the backlog: `players` bio, `teams` + NBA-id bridge, `player_quarter_box`.
- Series-slug matching currently keys on DEN's nickname; generalize to a teams/nickname map for all clubs.

> ✋ **Gate: paused for sign-off before Phase 2.**

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

## Phase 2 Reflection — 2026-06-08

Telos: scale from one team to all 30; prove throughput, schema robustness, and that the *actual* 2025 Finals are findable.

### Run the test

`sql/v2/091_phase2_test.sql` — **all 12 assertions pass.** 1,320 games (all 30 teams), 2,588→~31K box rows, 1,320 games with officials, 11,074 inactive rows, **0 quarantined** (after recovering 1 transient network failure with a targeted re-fetch).

| | Check | Result |
|---|---|---|
| 1-2 | 1,320 games, all 30 teams | ✓ |
| 3 | **2025 Finals present + labeled `round='Finals'` (7 games)** | ✓ |
| 4 | all canonical rounds (Play-In, First Round, Conf Semis, Conf Finals, Finals) | ✓ |
| 5 | no playoff game mislabeled Regular Season | ✓ |
| 6-7 | domain guard clean; team totals reconcile | ✓ (0 / 0) |
| 8-9 | officials for all 1,320 games; 11,074 inactives | ✓ |
| 10 | parity vs V1 season=2025 | ✓ (v2=1320, v1=1321 — delta explained below) |
| 11-12 | metric_coverage intact (17); quarantine rate | ✓ (0) |

**The headline**: the query that started the rebuild — "describe the Finals game" — now resolves to **OKC 103, IND 91, Finals Game 7** (the 2025 title clincher). Not just labeled queryable, the *real* Finals.

### Reflect against goals and values

- **Throughput held**: ~1,320 games at the 3s crawl-delay (~70 min) with per-batch commits + game-level checkpointing. Proven resumable when 1 game failed transiently — recovered with a targeted re-fetch, no full re-scrape.
- **The guard's first real all-teams test**: quarantined exactly 1 game, and *correctly* — a `ConnectionReset`, not bad data. Zero false quarantines, zero bad rows loaded. Quarantine-not-poison works as designed.
- **Single source held at scale** — every id BR-native across 30 teams.
- **We investigated the parity delta instead of waving it through** (the value in action): the 1 missing game is the **2024 NBA Cup Championship** (`202412170OKC`, MIL def. OKC). BR omits the Cup final from team-season game pages because it's the one Cup game not counting toward regular-season stats — a real competition-context ontology edge (our audit's "NBA Cup" row), not a bug.
- One subtlety found: a quarantine from a *transient* error is treated as "done" by the checkpoint, so it won't auto-retry. Acceptable (a re-run with the quarantine row cleared retries it, which is what we did), but Phase 3's longer runs want an explicit transient-vs-permanent quarantine distinction.

### Favors for future-us

- The recovery path (clear quarantine row → targeted re-fetch) is proven; Phase 3/4 will need it.
- NBA Cup final gap is documented + backlogged with the fix.
- `src/nba_ingest/v2/slice.py` carried all-teams scale unchanged — ready for Phase 3's historical eras.

### Open for Phase 3

- The hard part: pre-modern eras. `metric_coverage`'s pre-tracking NULLs (no steals pre-1974, no 3P pre-1980) get their first real exercise; `is_starter`, `attendance`, franchise relocations, and the guard all face data they've never seen.
- Distinguish transient vs permanent quarantines so long runs self-heal.

> ✋ **Gate: paused for sign-off before Phase 3.**

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

## Phase 3 Reflection — 2026-06-09

Telos: stress-test era handling on the hard part (history). Slice: **1972-73** (the pre-tracking boundary season). It surfaced two distinct problems — one the guard caught, one only survivor analysis caught.

### Run the test

`sql/v2/092_phase3_test.sql` — **all 10 assertions pass.** 738 games loaded into the *same* schema as 2025; 1973 Finals labeled (5 games, NYK champs); domain guard + reconciliation clean; both eras coexist in one table.

### Finding 1 — era parse bug (the guard caught it)

44 games quarantined on team-total reconciliation: every player parsed as 0 points. Root cause: pre-~1985 box scores omit `MP` for players who clearly played (Maravich, 39 pts, MP=NaN), and the flattener inferred "Did Not Play" from missing minutes and **zeroed real stats**. The guard converted silent corruption into a loud, contained quarantine. Fixed (parse stats directly; never infer DNP from minutes); verified the fix resolves **44/44** quarantines exhaustively, not by sampling.

### Finding 2 — coverage model error (only survivor analysis caught it)

The games that *passed* the guard encoded a wrong belief. My Phase 0 generalization from n=2 sample games — "pre-1974 has no steals/blocks" — was wrong at n=738: BR has **sparse but real** 1972-73 steals/blocks/turnovers (0.2-0.6% present; Wilt's blocks, Haywood's steals — plausible, season-spread, *not* corruption — verified by value plausibility + sparsity ruling out misalignment). The era boundary is a **ramp, not a cliff**. Corrected `metric_coverage` accordingly (and distinguished it from `fg3`, which IS a true cliff — the line didn't exist). The data was never corrupt; my model of it was.

### Reflect against goals and values

- **Loud-failing is necessary but not sufficient.** The guard catches missing/impossible data; it cannot catch a *plausible-but-wrong belief* baked into data that loads cleanly. Survivor analysis (inspecting what passed, per Zack's prompt) is the complement — and it found the deeper error. New durable practice: every era slice gets a survivor pass, not just a quarantine review.
- **Small samples over-generalize.** Phase 0's n=2 became a registry "fact." The fix is to treat Phase-0-era findings as *hypotheses* until a full-season load confirms them — which is exactly what slicing did.
- **Single source / single schema held**: 1972-73 dropped into the identical tables (validated the grain-not-era table rule now in REBUILD_METHOD §3).
- No values-diverging pivot; the parse fix and model correction both moved *toward* the telos.

### Favors for future-us

- `metric_coverage` now distinguishes **ramp** (recording coverage: stl/blk/tov) from **cliff** (existence: fg3) — a sharper model for every future era query.
- `dev/_load_season.py` + schedule enumeration is the proven backfill spine (handles defunct franchises, 404 months, transient retries, checkpoint resume).
- The DNP-from-minutes bug is a known era trap, documented in the flattener.

### Open for Phase 4 (full backfill)

- A clean full reload with the *final* flattener (the modern 2025 rows predate the DNP fix — cosmetic DNP-representation drift; reload-on-fix backlog covers it; Phase 4 normalizes everything).
- Pre-1971 seasons: Division (not Conference) playoff rounds (handled in code, untested); BAA-era meta gaps.
- Sustained multi-day GHA runs (this 738-game season was ~37 min; the full history is ~3-5 days).

### Post-gate survivor + audit pass (2026-06-09)

A survivor-bias sweep on the *landed* 1973 data (inspecting what PASSED, not just what failed) found three more era issues the tests had missed — all fixed:
- **is_starter**: ~28% of 1973 team-games lack BR's "Reserves" separator → whole roster was marked starter. Fixed (`None` when absent); test strengthened to assert per-team count ∈ {0,5}.
- **series_slug**: 5 NYK-vs-BAL (Baltimore Bullets) playoff games unmatched (BAL isn't a current franchise) → `match_series` now matches on *either* nickname.
- **"George Johnson" ×2** (GSW vs HOU, same game): two *distinct* players colliding on one resolved slug — NOT a duplicate; a naive dedup dropped a real player and the reconciliation guard caught it. Kept both; backlogged per-row slug resolution.

1973 reloaded with the fixes; **all 12 strengthened assertions pass.**

Then built **`dev/_audit.py`** — the standing anomaly-surfacing gate (`REBUILD_METHOD §7`), the systematic answer to "what else did we miss?". Definitive run on full 1973+2025: **2 flags, 42 green** — both flags adjudicated (the George-Johnson collision [known, backlogged]; `arena_state` sparse pre-modern [old `scorebox_meta` omits state, accepted]). The reactive survivor treadmill is replaced by an automatic, coverage-aware detector that converges.

> ✋ **Gate: paused for sign-off before Phase 4 (the multi-day full backfill).**

---

### Self-aware data: the exception-ledger architecture (2026-06-10)

A second "what did we miss?" pass — this time on the *audit itself* — found its deepest blind spot is the same as the bias it's named for: **every detector reads rows that exist; none establish that the rows that *should* exist *do*.** The audit's universe is `SELECT DISTINCT season FROM games` — it is structurally blind to **absence** (a dropped game, an un-enumerated game, an absent season). `quarantine` catches games we *tried and rejected*; nothing caught games we *never tried*.

The fix is an architecture, not a detector. The system has exactly **three dispositions toward a game**, each a typed ledger sharing one column vocabulary (`subject, type, detail, magnitude, first_seen/last_seen, status`); promotion between them is a row move:

| Ledger | Disposition | Grain |
|---|---|---|
| `quarantine` | **excluded** (failed the gate) | game (= slug) |
| `data_caveats` | **included, flagged** (real but known-imperfect) | game / player |
| `audit_findings` | **pending judgment** (system found it, we haven't ruled) | season / game / column / player |

Three tables, **not one** (unification would be the overengineering we keep guarding against — disposition toward the dataset is a real semantic boundary). Plus two guards that keep the ledgers honest:
- **Completeness** — the only check that looks at what *isn't* there. Shipped: schedule-reconciliation (`enumerate == loaded ∪ quarantined`; residual = silently dropped — catches the *demonstrated* failure mode, free). **Staged** (own phase, needs a standings fetcher): the independent `Σ(team G)/2` oracle that also catches a true gap in BR's schedule source.
- **The strict guardrail** (2026-06-10, Zack's call — *"if a game is flagged by ANY guardrail, I don't want it admitted on caveat. Quarantine for review, and then if approved, admit with caveat. There should never be a question of subverting the guardrails."*): ingest is **binary** — clean → admit; **ANY flag → quarantine**. The earlier admit-with-caveat-*at-ingest* (small reconciliation/line-score gaps auto-admitted below a ceiling) is **removed** — it *was* the subversion (the guardrail noticed a problem and the game walked in anyway). `guard()` now returns `issues` (no auto-admit bucket); `build_game(approve=False)` quarantines on any issue and writes **no** caveat. A caveat is written **only** by the human-driven `dev/_approve.py` (`build_game(approve=True)`), which re-admits a *reviewed* game and records its issues — so `data_caveats` now means exactly *"a human approved this game knowing this imperfection."* The risk was real and already-realized: game `195003160DNN` had been auto-admitted with a magnitude-**57** line-score caveat (a 1950 BAA box score, ~half the quarter cells parsed). Orientation ambiguity also quarantines now (was a soft admit+finding). The `CAVEAT_*` ceilings survive only as the `hard` **triage hint** in the quarantine record (`guard_blocker` vs `data_discrepancy`), never as admit gates. Two audit guards retained: dimension-scoped suppression (a caveat silences *only its own* detector — "caveated ∴ all-clear" is a category error) and the caveat-rate meta-detector (proliferation = a systematic bug). The ~30 games auto-admitted under the old rule are **re-quarantined at the gate** (`dev/_remediate_caveats.py`) and re-admitted via approval — `data_caveats` is empty until then.

**Guards don't auto-loosen** (2026-06-10, Zack's governing principle — *"I don't want to build a system that lets a reviewed type through suddenly just because we reviewed one instance of it. Guards are guards. We don't loosen them without confidence after many examples that the pattern can be loosened appropriately — an intensely reviewed process with a human in the loop."*): the review buckets (quarantine for game-grain, `audit_findings` for season/column-grain) hold anomalies for **intentional** review. Approving one instance admits *that instance* — it must **never** teach the system to auto-admit the pattern. No learned allowlists, no "we've seen this before so skip the check." Loosening a guard (ceasing to flag a pattern) is a separate, deliberate, evidence-heavy code change with a human in the loop — not an emergent behavior. Corollary worked through 2026-06-10: a **missing playoffs page** is a season-level anomaly. The first fix silently `return []`'d (admit the season without a bracket) — that was the *same* anti-pattern as auto-admit-on-caveat (the system deciding an anomaly is fine). Corrected: `fetch_playoff_series` raises `PlayoffsPageMissing`; the historical loader **blocks the season** and records a `missing_playoffs_page` finding for review, loading only when a human passes `--approve-no-playoffs` (per-instance, every time — it does not allowlist 1947-49). Daily settle treats a missing page as *expected* (an in-progress season's playoffs haven't started) — the policy lives in the caller, not in a loosened guard.

**Evidence-grounded correction (2026-06-10) — why the adjudication must be evidenced.** Double-checking the 1947-49 rationale *before* approving revealed they were **not** a true missing-playoffs case at all: those are the **BAA** (pre-1949 merger) and live under BR's `BAA_` URL prefix; our code hardcoded `NBA_{season}`. Evidence: `/playoffs/BAA_1947.html`, `/leagues/BAA_1947_games-november.html` → 200; the `NBA_1947` forms → 404; playoff slugs are `1947-baa-finals-...` and rounds are Quarterfinals/Semifinals/Finals. Real fix: `league_for(season)` (BAA ≤1949, NBA ≥1950) across the schedule + playoffs URLs, an `(nba|baa)` slug regex, and the BAA round names. Validated: 1947 enumerates **350 games** and its bracket classifies correctly. **The lesson, reinforcing the principle:** a guard firing tells you *something* is wrong, never *what* — had I "approved it as a structural gap," I'd have admitted three **near-empty** seasons (the schedule pages were under `BAA_` too, so `NBA_` enumeration returns zero games) on a false premise. The block-for-review machinery stays correct for a genuinely missing page; the *adjudication of why* must be grounded in referenceable evidence, never an unverified story. Residual known gap: BAA playoff `series_slug` linkage is NULL (defunct-team nicknames unmapped — same soft class as the 1973 Baltimore Bullets); games load with correct round/season_type.

**Line-score completeness — contradiction vs absence (2026-06-11).** The first BAA load surfaced two more things (the run also crashed on a `PARSE_JSON`-in-`VALUES` bug — fixed to `SELECT ... FROM VALUES`). (1) BR's early line scores are *incomplete* (Q1/Q2 blank, total correct) or *absent*; our reconciliation summed `NULL→0` and quarantined the whole era — a `NULL≠0` violation that flagged **absence as contradiction**. (2) The line-score table was required-to-load. Resolution (Zack's call: *"we DO want to flag absence — so we can devise honest solutions — but the NULL→0 is bad"*): two distinct guards. **Reconciliation** (contradiction) now reconciles quarters-vs-total ONLY when all of Q1-Q4 are present (never coerces), still firing on complete-but-mismatched quarters / `line_total≠game_total` / box reconciliation. **Completeness** (absence) is *raised* by a new audit detector that flags incomplete/absent line scores **in a season that's otherwise ≥90% complete** (a real anomaly) while treating a uniformly-sparse era as the documented ramp — data-driven, no hardcoded year. The line-score table is now best-effort enrichment (its absence doesn't block a valid game). Documented in `metric_coverage` (`line_score_quarters`, `recording_ramp`, `sql/v2/053`). Verified: 30/30 sampled 1947 games now admit (was ~all quarantining); partial quarters store NULL-honest.

**Admission-after-review mechanism (M3, chosen 2026-06-10 from a 3-way binary-rubric brainstorm).** How a reviewed game is admitted *without loosening the guard*: approval **provenance lives on `data_caveats`** itself (`reviewed_by`, `reviewed_at`, `review_note`) — the imperfection and the human accountability for admitting it are one row. `dev/_approve.py` is the only writer; **friction is structural** — each game must be named explicitly (the `--all`/`--reason-class` bulk paths were *removed* — that had been an easy-loosening hole), and `--reviewer` + `--note` are mandatory. The modeler agent sees it at query time via `DERIVED.vw_data_caveats` (now carrying the provenance). The key property (Zack: *"you could just build a view off that"*): because provenance is a column on the single `data_caveats` table, any "interesting findings / reviewed admissions" surface is **a view, never a copy** — it can't drift from the truth. Season-level admissions (`--approve-no-playoffs`) are equally gated (`--reviewer`/`--note` required) and recorded as an `audit_findings` row transitioned to `status='approved'` with the rationale. Rubric verdict: the new-table option failed *proportionate* (duplicates `data_caveats`); the git-gated-artifact option failed *agent-visible* (lives in the repo, not the DB) and *proportionate* (heavy); M3 passed all six (guard-intact, per-instance, deliberately-hard, traceable, agent-visible, proportionate). Schema: `sql/v2/051_caveat_provenance.sql` (applied 2026-06-10).

**Quarantine schema (locked)** — game-grain, because the slug deterministically yields `game_date`/`home_team_abbr`/`season` *even on total failure*, so a quarantine row is never empty. Typed axes we always slice on (`game_id, season, game_date, home/away_abbr, reason_class, failure_stage, status`) + a `VARIANT context` for stage-specific diagnostics (`blockers`, `missing_tables`, `http_status`); a field graduates from the blob to a column when a query earns it. It's a **worklist, not a graveyard**: loaders `MERGE` on `game_id` and **DELETE on later success**, so a falling open-quarantine count is a real signal of parser progress. `DERIVED.vw_quarantine_rate` (per season × reason × stage) is the completeness ally — a rate spike is a systematic parse bug masquerading as "that era was just bad."

**Orientation tripwire** (tier-2 home/away): `_find_team_abbrs_from_tables` silently guesses by table-order when the slug-home isn't among the box tables (BR lists *away* first → possible swap), logging only a warning the audit never reads. Fix is fail-loud-at-the-cause: orientation ambiguity is an ingest issue → the game **quarantines** for review (it is never admitted on a guess); the audit backstop asserts `home_team_abbr = RIGHT(game_id,3)` as a net for already-admitted data. **No learned allowlist** — every mismatch is reviewed individually; we do not auto-loosen the guard from past reviews.

**Application split (protecting the running 1947–59 backfill):** that job carries a frozen `5a8e7a1` code snapshot, so new commits can't perturb it. Brand-new `audit_findings` + read-only detectors apply now; the live `quarantine` migration + loader swap deploy at the post-backfill gate so the *next* chunk picks up the new loader — never mid-`INSERT`.

**Post-backfill gate sequence (when the running chunk completes):**
1. `apply_sql.py sql/v2/060_quarantine.sql` — migrate quarantine to the rich worklist schema.
2. `apply_sql.py sql/v2/061_quarantine_test.sql` — confirm the migration (5 checks).
3. `_remediate_caveats.py` (preview → `--apply`) — re-quarantine ALL ~30 admitted-on-caveat games (data_caveats → empty).
4. `_approve.py` — review the worklist; bulk-approve the legit soft discrepancies (`--reason-class data_discrepancy`), re-writing their caveats.
5. `_audit.py --completeness` across all loaded eras — the first run that tests *absence* for real.
6. **`git rm dev/_remediate_caveats.py`** — one-time migration artifact; delete it once the backlog is drained (the strict guardrail means no new admitted-on-caveat games exist, so it's dead weight). `dev/_approve.py` stays (durable).
7. (loader swap is already on `main`; the next chunk picks up `insert_quarantine` + drain automatically.)

> **Durable vs one-time tooling:** `_approve.py` = permanent (the human-approval path). `_remediate_caveats.py` = one-time (clean up the old auto-admit backlog, then delete). General principle — migration/remediation scripts clean up *behind* us as we go; they don't accrete in `dev/`.

> ✋ **Gate: each piece validates against the 1947–59 chunk as it lands (test-as-we-go).**

---

### Phase 4 — Full historical backfill (~3-5 days wall time, ~0 active effort)

**Goal**: populate everything else.

**Pre-backfill boundary probe (do FIRST — cheap insurance before the multi-day run):**
Before triggering the full scrape, probe a few games (in-memory, no load) from the *riskiest untested era boundaries* so a systematic spine bug is caught in minutes, not after 5 days of scraping + a re-scrape. Done 2026-06-09 for 1950 (BAA), 1965 (Division-playoff), 1980 (3P): parse/guard/reconcile clean across all; `is_starter` correctly NULL pre-separator; Finals tagged in every era. Caught + fixed one gap — `fetch_playoff_series` didn't classify pre-1971 `division-semifinals`/`division-finals` slugs (games' `round` was right from the `<h1>`, but series didn't link). Generalize this: any future bulk run gets a boundary probe first.

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
- ⚠️ **BLOCKER — the daily cron must be on V2 logic BEFORE this rename.** `daily_settle.py` is V1 code (the `LEFT(game_id,1)` season_type/round bug). A rename alone leaves the cron writing *new* games into the renamed DB with the old broken logic — silently re-introducing the exact bug the rebuild fixed, one day after cutover. Cutover prerequisite: ship the V2 daily-ingest "settle today" path (Deferred backlog → "V2 daily-ingest path") on the `_load_season.py` spine, point the cron at it, then rename. This is the difference between a fixed dataset and a fixed *pipeline*.
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
| `players` bio table | player · BR player page | Needs a per-player page fetch; not in the Phase 1 boxscore-only slice | Phase 2, or any bio/age/college query | Deferred |
| `teams` table + NBA-Stats `team_id` bridge | team | V2 uses BR abbr as canonical team id; the NBA-id bridge is only for cross-dataset joins | cross-dataset joins, or "best team ever" work | Deferred |
| NBA Cup Championship game ingestion | game · Cup bracket / date-index | team-season pages omit the Cup final (only Cup game not counting toward reg-season stats); found as the Phase 2 V1-parity delta (`202412170OKC`) | NBA Cup queries, or full-parity pass | Deferred |
| **Normalized `line_score_periods` table** | (game, team, period, points) · re-derive from box | The wide `line_scores` (~26 per-period columns: q1-4, ot1-6, ×2) is the *repeating-groups* anti-pattern — forced an `ot5/ot6` schema bump for the 5/6-OT games (2026-06-14) and an `or`-fallback that dropped 0-point OTs to NULL. A long table (one row per period) handles any OT count with no schema churn, stores 0 faithfully, represents absence as absent rows, and is era-agnostic (BAA halves too). Migration would also re-derive pre-2010 games whose 0-point OTs landed NULL under the old `or` bug. | Zack's architectural prompt 2026-06-14; do as a deliberate refactor (not mid-backfill) — wide model is *complete* for NBA history now (6 OT max) | Deferred |
| BAA team nicknames for `series_slug` linkage | (abbr → nickname) · BAA playoff slugs | BAA defunct teams (PHW, CHS, NYK, WSC, CLR, DTF, PIT, BOS, PRO, STB, TRH, ...) unmapped in `TEAM_NICKNAMES`, so BAA playoff games (season≤1949) load with correct round but `series_slug=NULL`. Documented in `metric_coverage` (`series_slug`, status `enrichment_pending`) + the `games.series_slug` column comment. | BAA playoff-series queries, or full-history series-linkage pass | Deferred |
| Transient vs permanent quarantine | (orchestrator) | a network-error quarantine is currently treated as "done" by the checkpoint, so it won't auto-retry | Phase 3 (long historical runs need self-healing retries) | Deferred |
| **V2 daily-ingest path (`settle` mode)** | orchestrator · `_load_season.py` spine | **Cutover prerequisite**: the current daily cron is V1 (`daily_settle.py` with the `LEFT(game_id,1)` bug); after rename it would write new games with the old broken logic and re-introduce the season_type/round bug. Needs a "settle today" mode on the V2 spine. | **Before Phase 6 cutover** | **Built** — `dev/_settle.py` + `.github/workflows/v2_daily.yml` (manual now; enable the cron + retire the V1 cron AT cutover) |
| Coverage-aware guardrail views (per stat) | `DERIVED.*` · joins `metric_coverage` | `vw_career_steals_leaders` seeds the pattern; blocks/tov/3P/leaders want the same era-scoping so aggregations never sum a not-tracked NULL as 0 | when a leaderboard / career-total query class is needed | Seeded (steals) |
| Reload-on-fix path for loaders | orchestrator | checkpoint skips already-loaded `game_id`s, so a flatten fix does NOT propagate to loaded games without manual deletion; want a `--reload` / logic-version stamp | when a flatten bug is fixed after a load | Deferred |
| `player_id` name-collision (same-name players) | flattener · `_extract_player_anchors` `{name: slug}` | two DISTINCT players with identical display names in one game collapse to one resolved slug (Phase 3 gut-check: two "George Johnson", GSW vs HOU, both `johnsge02`). Needs per-row slug resolution instead of a name→slug dict. Rare (~1 in 31k); do NOT dedup (drops a real player). | when frequency warrants, or Phase 7 | Deferred |
| Agent-harness golden-truth tests (cross-repo) | agentic harness, NOT this repo | external basketball truths (1973 Finals = NYK champ; Wilt 100 = 1962; Dyson Daniels led steals 2024-25) belong as **agent-level** tests run by the harness against these DBs — the real proof of the goal, vs. SQL assertions here | cutover / harness work | Deferred |

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
