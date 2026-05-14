# NBA Ingest Plan

> **Status (2026-05-14):** Slice 0 complete (JB_HISTORIC_NBA surveyed and validated). Slice 1 pending (ZK_NBA bootstrap + JB seed). All SQL and Python scaffolding written — ready to execute.

---

## Handoff — Start Here

### Slice status

| Slice | Name | Status |
|-------|------|--------|
| 0 | JB_HISTORIC_NBA validation | DONE — see "Validated facts" below |
| 1 | Bootstrap ZK_NBA + seed from JB | PENDING — run `sql/001_bootstrap.sql` then `sql/050_seed_from_jb/*.sql` |
| 2 | BR catch-up scraper (2023-present) | PENDING — depends on Slice 1 |
| 3 | Daily GHA cron | PENDING — depends on Slice 2 |
| 4 | Advanced box scores (historical, BR-only) | PENDING — depends on Slice 2 |
| 5 | Draft class career stats + weekly metadata | PENDING — depends on Slice 3 |
| Demo | Point modeler at ZK_NBA.FLAT | PENDING — depends on Slice 1 for historical; Slice 3 for live |

### Validated facts from JB_HISTORIC_NBA.PUBLIC

Surveyed 2026-05-14. All row counts confirmed against live Snowflake account.

| Table | Row count | Date range | Notes |
|-------|-----------|------------|-------|
| PLAYERSTATISTICS1 | 811,672 | 2001-12-30 to 2025-04-06 | 35 cols; modern player box |
| PLAYERSTATISTICS2 | 811,671 | 1946-11-26 to 2001-12-30 | 35 cols; historical player box; date-split complement |
| GAME | 65,642 distinct | 1946–Jun 2023 | 55 cols, wide format (1 row = both teams) |
| LINE_SCORE | 58,053 | modern | Quarter-by-quarter, wide format |
| OFFICIALS | 70,971 assignments | modern only | 235 distinct officials, 23,575 games |
| INACTIVE_PLAYERS | 110,191 | modern | — |
| PLAYERS2 | 6,533 | — | 14 cols; includes booleans for G/F/C positions |
| TEAM | 30 rows | — | Current teams only |
| TEAM_DETAILS | 25 rows | — | Missing ORL, NYK, BOS, CLE, NOP |
| DRAFT_HISTORY | 7,990 | 1947–2023 | 14 cols |
| DRAFT_COMBINE_STATS | 1,202 | — | Combine measurements |
| PLAY_BY_PLAY_PART001 | 1,208,387 | 2,678 distinct games | 34 cols |
| PLAY_BY_PLAY_PART002 | 1,208,387 | 2,660 distinct games | 34 cols; 1 overlapping game with PART001 |
| GAME_SUMMARY | 58,110 | — | 14 cols; includes broadcaster, status |
| TEAMHISTORIES | 140 rows | — | Team relocations and name changes |

**Union of PLAYERSTATISTICS1 + PLAYERSTATISTICS2:** ~1,623,343 rows, 1946-11-26 to 2025-04-06.

**Gap to fill from BR:**
- GAME records: 2023-24, 2024-25, 2025-26 seasons (everything after Jun 2023)
- PLAYERSTATISTICS: 2024-25 playoffs + 2025-26 season (JB1 ends Apr 2025, but gaps in late 2024 playoffs)
- Advanced box scores (TS%, eFG%, BPM, ORtg, DRtg): all seasons (not in JB at all)
- 5 missing TEAM_DETAILS rows: ORL, NYK, BOS, CLE, NOP
- Draft 2024, 2025 classes
- Draft class career stats (BR draft pages, auto-updating)

---

## Goal

Pump NBA stats data from two sources into `ZK_NBA.FLAT` so it's queryable through modeler. No analytics in the pipeline — flat relational data only. All analysis (career stats, rolling averages, comparisons) happens at query time via the agent.

**v1 scope:** 1946-present player box scores, game results, line scores, officials, players, teams, draft history, play-by-play (modern), advanced box scores (2023-present from BR).

---

## Architecture

Two-tier Snowflake: raw VARIANT + flat relational. No analytics tier. Agent computes at query time.

### Tier 1: RAW

Append-only VARIANT store. Exactly what Basketball-Reference returned (HTML as text, or parsed JSON blob). Used for:
- Debugging (compare raw to flat if something looks off)
- Re-flattening if FLAT schema changes (reprocess without re-scraping)
- Audit trail

For the JB seed, there is no RAW tier — we copy JB's already-structured data directly into FLAT via CTAS.

### Tier 2: FLAT

Flattened relational tables. Typed columns, column-level comments, natural keys enforced via PRIMARY KEY declarations (Snowflake notes but doesn't enforce — deduplication is the job's responsibility).

Flatten happens in Python (`src/nba_ingest/flatteners/`) for BR-scraped data. For JB-seeded data, CTAS SQL handles the transform directly.

### Scheduling

GitHub Actions cron drives all ongoing ingestion. No Snowflake tasks. Same architecture as wow-ingest after its migration:

```
GitHub Actions cron (daily_settle.yml, 8:30 UTC)
  └─ python -m nba_ingest.jobs.daily_settle
       └─ BR: GET /boxscores/?month=M&day=D&year=Y  (list game slugs)
       └─ BR: GET /boxscores/{slug}.html  (one per game, 3s delay each)
       └─ flatten in Python
       └─ Snowflake MERGE INTO ZK_NBA.FLAT.{games, player_box_basic, player_box_advanced,
                                              line_scores, game_officials, game_inactives}
```

---

## Data Sources

### JB_HISTORIC_NBA.PUBLIC (Snowflake seed, one-time)

Existing Snowflake database on the modeler team account. Contains NBA Stats API data 1946–Apr 2025 for player stats, 1946–Jun 2023 for games. The seed is a one-time CTAS operation — no ongoing dependency on JB after Slice 1.

**Account:** `ndsoebe-rai_int_modeler_team_aws_us_west_2_consumer` (same account as ZK_NBA — cross-DB CTAS works natively).

### Basketball-Reference (ongoing)

URL: https://www.basketball-reference.com. Operated by Sports Reference LLC.

Data-sharing policy explicitly permits reuse with attribution. See `LICENSES.md`.

**Crawl-delay:** 3 seconds per `robots.txt`. Enforced in `br_client.py`.

**Content rendering:** All content is server-side rendered. No JS execution required. Standard `requests` + `BeautifulSoup` with `html5lib` parser.

**Key quirk:** Some tables (line_score, four_factors) are hidden inside HTML comments (`<!-- <table>...</table> -->`). Must be extracted with comment-parsing before BS4 can see them.

### NBA.com (OUT OF SCOPE)

Explicitly excluded. NBA.com Terms of Service Section 9.vii prohibits creation or maintenance of databases of regularly updated statistics from their site. The JB seed uses data originally from NBA.com — that's a one-time operation on already-existing data and is treated as acceptable. No ongoing NBA.com scraping.

---

## Snowflake Schema

**Database:** `ZK_NBA`
**Account:** `ndsoebe-rai_int_modeler_team_aws_us_west_2_consumer`
**Role:** `DEVELOPER_ADMIN`
**Warehouse:** `NBA_INGEST_WH` (XSMALL, AUTO_SUSPEND=60)
**Schemas:** `RAW`, `FLAT`, `DERIVED`

### FLAT tables

| Table | Grain | Key | Source |
|-------|-------|-----|--------|
| `games` | 1 row per game | `game_id` | JB seed (1946–Jun 2023) + BR scrape (2023-present) |
| `player_box_basic` | 1 row per player per game | `(game_id, player_id)` | JB seed (1946–Apr 2025) + BR scrape (gap fill + ongoing) |
| `player_box_advanced` | 1 row per player per game | `(game_id, player_id)` | BR scrape only (2023-present; not in JB) |
| `line_scores` | 1 row per game (home+away wide) | `game_id` | JB seed + BR scrape |
| `game_officials` | 1 row per official per game | `(game_id, official_id)` | JB seed (modern) |
| `game_inactives` | 1 row per inactive player per game | `(game_id, player_id)` | JB seed (modern) |
| `players` | 1 row per player | `player_id` | JB seed (PLAYERS2) |
| `teams` | 1 row per team (current) | `team_id` | JB seed (TEAM + TEAM_DETAILS, 25/30) + BR supplement (5 missing) |
| `team_history` | 1 row per team-name-era | `(team_id, year_founded)` | JB seed (TEAMHISTORIES) |
| `draft` | 1 row per draft pick | `(season, overall_pick)` | JB seed (1947–2023) + BR scrape (2024-2025 classes) |
| `draft_combine` | 1 row per combine participant | `(player_id, season)` | JB seed (DRAFT_COMBINE_STATS) |
| `draft_career_stats` | 1 row per draftee (annually refreshed) | `(season, overall_pick)` | BR scrape (weekly_meta job) |
| `play_by_play` | 1 row per PBP event | `(game_id, event_num)` | JB seed (PART001 UNION PART002) |

---

## Vertical Slices

### Slice 0: JB_HISTORIC_NBA Validation (DONE)

Surveyed source tables, confirmed row counts and schemas. Results documented in "Validated facts" above.

No code changes. Output: this plan doc + SQL files for Slice 1.

---

### Slice 1: Bootstrap ZK_NBA + Seed from JB

**Goal:** Fully populated `ZK_NBA.FLAT` with 1946–2025 historical data, ready for the BR catch-up in Slice 2.

**Steps:**

1. Run `sql/001_bootstrap.sql` — creates `ZK_NBA` database, `RAW`/`FLAT`/`DERIVED` schemas, `NBA_INGEST_WH` warehouse.
2. Run `sql/020_raw_tables.sql` — creates RAW variant tables.
3. Run `sql/040_flat_tables.sql` — creates FLAT relational tables with column comments.
4. Run each seed file in order:
   - `sql/050_seed_from_jb/001_player_box.sql` — ~1.6M rows, may take 30-60s
   - `sql/050_seed_from_jb/002_games.sql` — ~65K rows
   - `sql/050_seed_from_jb/003_line_scores.sql`
   - `sql/050_seed_from_jb/004_officials.sql`
   - `sql/050_seed_from_jb/005_players.sql`
   - `sql/050_seed_from_jb/006_teams.sql` — note: 5 teams will have nulls (ORL/NYK/BOS/CLE/NOP)
   - `sql/050_seed_from_jb/007_draft.sql`
   - `sql/050_seed_from_jb/008_inactive.sql`
   - `sql/050_seed_from_jb/009_draft_combine.sql`
   - `sql/050_seed_from_jb/010_team_history.sql`
   - `sql/050_seed_from_jb/011_play_by_play.sql` — ~2.4M rows (2 parts merged)
5. Manual: supplement 5 missing TEAM_DETAILS entries (ORL, NYK, BOS, CLE, NOP) with data from BR team pages.
6. Run all validation gates below.

**Validation Gate 1 — Row counts**

```sql
SELECT 'player_box_basic'  AS t, COUNT(*) AS n FROM ZK_NBA.FLAT.player_box_basic
UNION ALL SELECT 'games',          COUNT(*) FROM ZK_NBA.FLAT.games
UNION ALL SELECT 'line_scores',    COUNT(*) FROM ZK_NBA.FLAT.line_scores
UNION ALL SELECT 'game_officials', COUNT(*) FROM ZK_NBA.FLAT.game_officials
UNION ALL SELECT 'game_inactives', COUNT(*) FROM ZK_NBA.FLAT.game_inactives
UNION ALL SELECT 'players',        COUNT(*) FROM ZK_NBA.FLAT.players
UNION ALL SELECT 'teams',          COUNT(*) FROM ZK_NBA.FLAT.teams
UNION ALL SELECT 'team_history',   COUNT(*) FROM ZK_NBA.FLAT.team_history
UNION ALL SELECT 'draft',          COUNT(*) FROM ZK_NBA.FLAT.draft
UNION ALL SELECT 'draft_combine',  COUNT(*) FROM ZK_NBA.FLAT.draft_combine
UNION ALL SELECT 'play_by_play',   COUNT(*) FROM ZK_NBA.FLAT.play_by_play
ORDER BY 1;
-- Expected:
--   draft             ~7,990
--   draft_combine     ~1,202
--   game_inactives    ~110,191
--   game_officials    ~70,971
--   games             ~65,642
--   line_scores       ~58,053
--   play_by_play      ~2,416,773 (PART001 + PART002, minus ~1 overlapping game's events)
--   player_box_basic  ~1,623,343 (PLAYERSTATISTICS1 + PLAYERSTATISTICS2 union)
--   players           ~6,533
--   team_history      ~140
--   teams             30
```

**Validation Gate 2 — Date ranges**

```sql
SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date FROM ZK_NBA.FLAT.games;
-- Expected: 1946-11-01 to 2023-06-12

SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date FROM ZK_NBA.FLAT.player_box_basic;
-- Expected: 1946-11-26 to 2025-04-06

SELECT MIN(season) AS min_season, MAX(season) AS max_season FROM ZK_NBA.FLAT.draft;
-- Expected: 1947 to 2023
```

**Validation Gate 3 — 2023 Finals Game 5 spot check**

```sql
-- Game record
SELECT game_id, game_date, home_team_abbr, home_pts, away_team_abbr, away_pts
FROM ZK_NBA.FLAT.games
WHERE game_date = '2023-06-12';
-- Expected: game_id=42200405, DEN 94, MIA 89 (Denver clinches championship)

-- Top scorers in that game
SELECT player_name, team_abbr, pts, ast, reb, plus_minus
FROM ZK_NBA.FLAT.player_box_basic
WHERE game_id = '42200405'
ORDER BY pts DESC
LIMIT 5;
-- Expected: Nikola Jokic at top (28 pts in Game 5)
```

**Validation Gate 4 — No orphaned official assignments**

```sql
SELECT COUNT(*) AS orphaned
FROM ZK_NBA.FLAT.game_officials o
LEFT JOIN ZK_NBA.FLAT.games g ON o.game_id = g.game_id
WHERE g.game_id IS NULL;
-- Expected: 0
-- Note: OFFICIALS in JB covers modern games; GAME only goes to Jun 2023.
-- If officials covers post-2023 games, this will not be 0 until Slice 2.
-- Acceptable: run this gate again after Slice 2.
```

**Validation Gate 5 — No duplicate player-game rows**

```sql
SELECT COUNT(*) AS dupes FROM (
    SELECT game_id, player_id, COUNT(*) AS n
    FROM ZK_NBA.FLAT.player_box_basic
    GROUP BY game_id, player_id
    HAVING n > 1
);
-- Expected: 0
-- If non-zero, investigate the UNION overlap between PLAYERSTATISTICS1 and PLAYERSTATISTICS2.
-- The two tables split at 2001-12-30 — check that boundary for duplicates.
```

**Validation Gate 6 — All 30 teams present**

```sql
SELECT abbreviation, full_name FROM ZK_NBA.FLAT.teams
WHERE abbreviation IN ('ORL', 'NYK', 'BOS', 'CLE', 'NOP');
-- Expected: 5 rows (manually inserted from BR after seed)
-- All 5 were missing from JB's TEAM_DETAILS (had 25/30)

SELECT COUNT(*) AS total_teams FROM ZK_NBA.FLAT.teams;
-- Expected: 30
```

---

### Slice 2: BR Catch-Up Scraper (2023-Present)

**Goal:** Fill the gap in FLAT.games (Jul 2023 to today) and FLAT.player_box_basic (Apr 2025 to today). Also populate FLAT.player_box_advanced for all seasons since 2023-24.

**Approach:** Run `backfill.py` one season at a time, starting with 2023-24:

```bash
BACKFILL_SEASON=2023-24 python -m nba_ingest.jobs.backfill
BACKFILL_SEASON=2024-25 python -m nba_ingest.jobs.backfill
# 2025-26 ongoing season handled by daily_settle once Slice 3 is live
```

Each season ~82 regular season games per team + playoffs. At 3s per game page + ~2 teams per game: ~25-30 min per season for regular season. Playoffs add ~20 games.

**Validation Gate 1 — Date range extended**

```sql
SELECT MIN(game_date) AS min_date, MAX(game_date) AS max_date FROM ZK_NBA.FLAT.games;
-- Expected after 2023-24 backfill: min unchanged (1946), max ~2024-06-17 (2024 Finals)
-- Expected after 2024-25 backfill: max ~2025-06-XX (2025 Finals)
```

**Validation Gate 2 — Season game counts**

```sql
SELECT season, COUNT(*) AS games
FROM ZK_NBA.FLAT.games
WHERE season IN (2024, 2025)
GROUP BY 1
ORDER BY 1;
-- Expected: ~1,230 regular season games per season (82 games × 30 teams / 2)
-- Plus ~85 playoff games per season
```

**Validation Gate 3 — Wembanyama NBA debut spot check**

```sql
-- Wembanyama's NBA debut: Oct 25, 2023, SAS vs DAL
SELECT game_id, game_date, home_team_abbr, home_pts, away_team_abbr, away_pts
FROM ZK_NBA.FLAT.games
WHERE game_date = '2023-10-25'
  AND (home_team_abbr = 'SAS' OR away_team_abbr = 'SAS');
-- Expected: 1 row, SAS vs DAL

SELECT player_name, team_abbr, pts, ast, reb
FROM ZK_NBA.FLAT.player_box_basic
WHERE game_date = '2023-10-25'
  AND player_name LIKE '%Wembanyama%';
-- Expected: 1 row (Wembanyama: 15 pts, 5 blk in debut)
```

**Validation Gate 4 — No date gaps in active season**

```sql
-- Count days in 2023-24 regular season (Oct 24, 2023 – Apr 14, 2024) with zero games.
-- There are known off-days (All-Star Break ~Feb 16-18, Christmas Day has games).
-- This query surfaces unexpected gaps.
WITH season_days AS (
    SELECT DATEADD(DAY, seq4(), '2023-10-24'::DATE) AS d
    FROM TABLE(GENERATOR(ROWCOUNT => 180))  -- ~6 months
    WHERE d <= '2024-04-14'
),
game_days AS (
    SELECT DISTINCT game_date
    FROM ZK_NBA.FLAT.games
    WHERE game_date BETWEEN '2023-10-24' AND '2024-04-14'
)
SELECT s.d AS gap_date
FROM season_days s
LEFT JOIN game_days g ON s.d = g.game_date
WHERE g.game_date IS NULL
ORDER BY 1;
-- Expected: ~30-40 off-days (All-Star, travel days, scheduled off-days)
-- Any unexpected run of 3+ consecutive off-days during active season = investigate
```

**Validation Gate 5 — Advanced stats populated**

```sql
SELECT COUNT(*) AS advanced_rows FROM ZK_NBA.FLAT.player_box_advanced;
-- Expected after 2023-24: ~(82+85 games × ~9 players per game per team × 2 teams) ≈ 22,000+

SELECT player_name, game_date, ts_pct, efg_pct, bpm
FROM ZK_NBA.FLAT.player_box_advanced a
JOIN ZK_NBA.FLAT.player_box_basic b USING (game_id, player_id)
WHERE b.game_date = '2023-10-25'
  AND b.player_name LIKE '%Wembanyama%';
-- Expected: 1 row with advanced stats for Wembanyama's debut
```

---

### Slice 3: Daily GHA Cron

**Goal:** Enable autonomous daily ingestion. After this slice, the pipeline runs without manual touchpoints.

**Steps:**

1. Generate a Snowflake PAT for the nba-ingest GHA user.
2. Set GitHub Actions secrets:
   ```bash
   gh secret set SNOWFLAKE_ACCOUNT -R ZKordeleski/nba-ingest
   gh secret set SNOWFLAKE_USER -R ZKordeleski/nba-ingest
   gh secret set SNOWFLAKE_PASSWORD -R ZKordeleski/nba-ingest
   gh secret set SNOWFLAKE_ROLE -R ZKordeleski/nba-ingest
   gh secret set SNOWFLAKE_WAREHOUSE -R ZKordeleski/nba-ingest
   ```
3. Uncomment the `schedule:` block in `.github/workflows/daily_settle.yml`.
4. Trigger a manual dispatch with yesterday's date to validate end-to-end before the cron fires.
5. Confirm cron fires on schedule (check GHA run history after 24h).

**Validation:** manual dispatch succeeds + next morning's cron run lands rows with the correct date.

---

### Slice 4: Advanced Box Scores (Historical, BR-Only)

**Goal:** Populate `FLAT.player_box_advanced` for all seasons with BR data (2023-24 is filled in Slice 2; this extends backward as far as BR has it).

**Note:** BR has advanced box scores going back to ~2001. Pre-2001 advanced stats are not available. This slice is a separate backfill job, not part of daily_settle.

Scope and implementation TBD. Add a `fetch_advanced_boxscore(game_id)` method that looks up games in FLAT.games and fetches the corresponding BR page.

---

### Slice 5: Draft Class Career Stats + Weekly Metadata

**Goal:** Keep `FLAT.draft_career_stats` current (BR draft pages update as players' careers progress) and refresh team metadata annually.

Jobs: `weekly_meta.py` (stubs written; implementation is this slice's work).

Cadence: Monday 8:30 UTC (`.github/workflows/weekly_meta.yml`).

---

### Demo Gate

Point modeler at `ZK_NBA.FLAT`. Requires Slice 1 for historical data, Slice 3 for live.

Initial demo queries:
- "Who led the 2023 Finals in points per game?"
- "Show Jokic's career trajectory in points, assists, rebounds"
- "Which players from the 2023 draft class are performing best by win shares?"
- "What was the most lopsided game of the 2024-25 season?"

Capture all friction in `FRICTION.md`.

---

## Cadence Schedule

| Job | Frequency | Trigger | Notes |
|-----|-----------|---------|-------|
| `daily_settle` | Daily, 8:30 UTC | GHA cron | Settles all games from the previous calendar day. 8:30 UTC = ~3:30am ET — all West Coast games are final. |
| `weekly_meta` | Weekly, Monday 8:30 UTC | GHA cron | Draft career stats refresh + team metadata. Low priority; runs during off-peak. |
| `backfill` | On-demand | Manual local run | Catch-up for a full season. Designed to be run once per season for historical fill. |

---

## Decisions Made

**1. JB seed as one-time CTAS, not ongoing dependency.**
JB_HISTORIC_NBA is someone else's table in the same Snowflake account — not a stable contract. We copy it once into ZK_NBA.FLAT and then maintain our own copy going forward via BR. This avoids surprise schema changes breaking our pipeline.

**2. BR as the ongoing source, not NBA.com.**
NBA.com TOS Section 9.vii explicitly prohibits database scraping for regularly updated stats. BR's data-sharing policy explicitly permits it. BR also has richer historical data and a more consistent HTML structure. Clear choice.

**3. games grain: 1 row per game, not 1 row per team-game.**
JB's GAME table is already 1-row-per-game (wide format). Keeping this grain in FLAT means half the rows, cleaner JOINs for game-level analysis. The home/away distinction is explicit in column names.

**4. player_box_basic grain: 1 row per player per game.**
The natural grain for player stats. PRIMARY KEY is (game_id, player_id). Deduplication on MERGE prevents double-counting when JB seed and BR scrape overlap.

**5. No advanced stats backfill before 2023-24 in v1.**
BR has advanced stats going back to ~2001, but extracting them for ~20 seasons would be a large crawl job. Slice 4 is scoped separately. For the demo gate, 2023-present is sufficient.

**6. play_by_play from JB only (modern games).**
JB has play-by-play for ~5,300 games (both parts combined, minus 1 overlap). BR has play-by-play in a different format. No ongoing BR PBP scraping planned for v1 — JB's data covers the interesting modern window.

**7. UNION (not UNION ALL) for play_by_play parts.**
One game appears in both PART001 and PART002. `UNION` deduplicates on all 34 columns. This is safe because PBP rows are fully deterministic for a given game.

**8. Snowflake warehouse: XSMALL, AUTO_SUSPEND=60.**
Matches wow-ingest. The daily settle job is lightweight (a few hundred rows per day). The initial backfill is the heavy operation — XSMALL is fine, just slower for the CTAS seed queries if needed.

---

## Open Questions

1. **PLAYERSTATISTICS boundary:** Do PLAYERSTATISTICS1 and PLAYERSTATISTICS2 overlap at the 2001-12-30 boundary, or is it a clean split? Validation Gate 5 (duplicate check) will answer this. If there's overlap, add a deduplication filter to the UNION.

2. **Missing 5 TEAM_DETAILS:** What are the correct arena/capacity/coach values for ORL, NYK, BOS, CLE, NOP? BR team pages have this but it requires manual lookup and may be stale (coaches change mid-season). For v1, nullable is acceptable.

3. **OFFICIALS coverage:** JB's OFFICIALS table covers "modern only" but the exact cutoff is unknown. After seeding, check `MIN(game_date)` for officials JOIN'd to games. If there's a gap pre-2000, it's expected.

4. **BR rate limiting:** POC tested 3s crawl-delay without issues. A season backfill (~1,300 games) takes ~65 minutes at 3s per game. If BR returns 429s, add exponential backoff (already stubbed in `br_client.py`).

5. **GAME_SUMMARY vs GAME:** JB has both GAME (55 cols, 65,642 rows, 1946–2023) and GAME_SUMMARY (58,110 rows). GAME_SUMMARY has broadcaster info and status fields that GAME lacks. Are they worth joining? Punted to later — GAME is sufficient for v1.

6. **Draft 2024/2025 classes:** Confirmed missing from JB (JB DRAFT_HISTORY goes to 2023). Fetch from BR in Slice 5.

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `sql/001_bootstrap.sql` | Create ZK_NBA, schemas, warehouse |
| `sql/040_flat_tables.sql` | FLAT table DDL with column comments |
| `sql/050_seed_from_jb/*.sql` | One-time seed from JB_HISTORIC_NBA |
| `sql/090_validation/*.sql` | Copy-paste validation queries |
| `src/nba_ingest/br_client.py` | BR HTTP client with crawl-delay + comment extraction |
| `src/nba_ingest/fetchers/boxscore.py` | Parse one game's BR page |
| `src/nba_ingest/fetchers/games.py` | List game slugs for a given date |
| `src/nba_ingest/jobs/daily_settle.py` | GHA-driven daily job |
| `src/nba_ingest/jobs/backfill.py` | Season-by-season historical backfill |
| `docs/SHAPES.md` | BR page shapes, table IDs, quirks |
| `.github/workflows/daily_settle.yml` | GHA cron — enable after Slice 3 |
