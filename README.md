# nba-ingest

Pipeline that pumps NBA stats from Basketball-Reference into Snowflake. Powers conversational analytics in modeler.

## Current status

**Production. Daily cron live (8:30 UTC) since 2026-05-15.** Data spans 1946-11-01 to present (~1.6M player-game rows, ~70K games, ~83K official assignments).

Source boundary (post-2026-05-15 canonical swap):
- **Pre-2023-24 season**: `jb_seed` — sourced from `JB_HISTORIC_NBA.PUBLIC` (NBA Stats API snapshot). NBA Stats numeric game_id format (e.g. `42200405`).
- **2023-24 season onward**: `br_scrape` — sourced from Basketball-Reference daily scraping. BR URL slug game_id format (e.g. `202405190DEN`).
- Clean cut at 2023-06-12 (end of 2022-23 NBA Finals). No same-game duplication; joins work within each era.

Slices A-I.1 complete. See [`HANDOFF.md`](HANDOFF.md) for the full session log and [`docs/plan.md`](docs/plan.md) for the original slice breakdown.

## Architecture

Two-tier Snowflake (raw VARIANT + flat relational). No analytics tier — the modeler agent computes analysis at query time.

Both tiers are written from one Python job per endpoint — there is no separate Snowflake-task layer. Flatten happens in plain Python (`src/nba_ingest/flatteners/`), and the same job that fetches from Basketball-Reference also writes the flattened rows to FLAT in the same warehouse cycle.

```
GitHub Actions cron
  └─ python -m nba_ingest.jobs.<job>
       └─ Basketball-Reference fetch (requests + BeautifulSoup, 3s crawl-delay)
       └─ flatten in Python → list[dict]
       └─ Snowflake MERGE INTO ZK_NBA.FLAT.<table>
```

For the historical seed (Slice 1), data flows directly from JB_HISTORIC_NBA → ZK_NBA.FLAT via CTAS SQL — no Python involved.

Naming: **database-per-domain, with `ZK_` prefix for personal scope** in the shared team account. `ZK_NBA` is one database with schemas `RAW`, `FLAT`, `DERIVED`. A parallel `ZK_WOW` database uses the same layout for WoW data.

**Data sources:**
- `JB_HISTORIC_NBA.PUBLIC` — existing Snowflake DB with NBA data 1946–2025 (seeded once)
- Basketball-Reference — catch-up scraper for 2023-present + daily ongoing (per BR's data-sharing policy; see `LICENSES.md`)
- NBA.com — explicitly **out** (TOS Section 9.vii prohibits database scraping)

## Quickstart

1. **Bootstrap Snowflake objects.** Run `sql/001_bootstrap.sql` against the modeler team account.
2. **Seed from JB.** Run each file in `sql/050_seed_from_jb/` in order.
3. **Validate.** Run `sql/090_validation/001_row_counts.sql` and compare against expected values.
4. **Configure local env.** `cp .env.example .env` and fill in `SNOWFLAKE_PASSWORD` with your PAT.
5. **Install.** `pip install -e .`
6. **Run BR backfill.** `BACKFILL_SEASON=2023-24 python -m nba_ingest.jobs.backfill`
7. **Configure GHA secrets** and enable the `daily_settle` workflow.

See [`docs/SETUP.md`](docs/SETUP.md) for step-by-step detail.

## Plan doc

Full plan (architecture decisions, slice breakdown, validation gates, open questions) lives at [`docs/plan.md`](docs/plan.md).

## Friction journal

As we use modeler against this data, every "I wanted to do X but had to leave the app" moment gets logged in `FRICTION.md`. That journal is load-bearing for the eventual writeback-to-Snowflake / derived-concept features.

## Layout

```
src/nba_ingest/
  br_client.py         Basketball-Reference HTTP client (fetch + table parser)
  snowflake_client.py  Snowflake connection + PUT/MERGE helpers
  fetchers/            One module per BR page type (extract only)
    games.py           List game slugs for a date
    boxscore.py        Fetch and parse one game's box score page
    schedule.py        Fetch monthly schedule
    draft.py           Fetch annual draft class
  flatteners/          Pure dict-to-row transforms — no I/O, unit-tested
    boxscore.py        Flatten basic/advanced box, line score, four factors, meta
    schedule.py        Flatten schedule DataFrame
    draft.py           Flatten draft career stats DataFrame
  jobs/                One module per scheduled job
    daily_settle.py    Settle yesterday's games (GHA cron daily)
    backfill.py        Backfill a full season (run locally)
    weekly_meta.py     Teams/draft metadata refresh (stubs — Slice 5 scope)

sql/
  001_bootstrap.sql              Database (ZK_NBA), schemas, warehouse
  020_raw_tables.sql             ZK_NBA.RAW.* (VARIANT payloads)
  040_flat_tables.sql            ZK_NBA.FLAT.* (flattened relational, column comments)
  050_seed_from_jb/              JB → FLAT seed scripts. Use DELETE WHERE source='jb_seed'
                                 (not TRUNCATE) for multi-source tables so BR rows survive
                                 a re-seed. Run in order on first bootstrap.
    001_player_box.sql           UNION of PLAYERSTATISTICS1 + PLAYERSTATISTICS2
    002_games.sql                GAME (wide format → flat games)
    003_line_scores.sql          LINE_SCORE
    004_officials.sql            OFFICIALS → game_officials
    005_players.sql              PLAYERS2 → players
    006_teams.sql                TEAM + TEAM_DETAILS → teams (25/30 from JB; 5 TBD from BR)
    007_draft.sql                DRAFT_HISTORY → draft
    008_inactive.sql             INACTIVE_PLAYERS → game_inactives
    009_draft_combine.sql        DRAFT_COMBINE_STATS → draft_combine
    010_team_history.sql         TEAMHISTORIES → team_history
    011_play_by_play.sql         PLAY_BY_PLAY_PART001 UNION PLAY_BY_PLAY_PART002
  060_xref_setup.sql             ZK_NBA.DERIVED.player_xref + official_xref
  070_derived_views/             ZK_NBA.DERIVED.* views computed at query time
    001_vw_team_box.sql          Team-level box stats (SUM player_box_basic GROUP BY team)
  090_validation/                Per-slice validation queries
  100_comment_refresh.sql        ALTER ... COMMENT updates for live DB (run once after fixes)
    001_row_counts.sql
    002_date_ranges.sql
    003_spot_checks.sql
    004_linkage_checks.sql

docs/
  plan.md              Full plan with slice breakdown and validation gates
  SETUP.md             Step-by-step setup guide
  SHAPES.md            BR page shapes and table IDs from POC

.github/workflows/
  daily_settle.yml     8:30 UTC daily — settle previous day's games
  weekly_meta.yml      8:30 UTC Monday — teams/draft metadata refresh
```
