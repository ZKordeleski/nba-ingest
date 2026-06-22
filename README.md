# nba-ingest

Pipeline that pumps NBA stats from **Basketball-Reference** into Snowflake (`ZK_NBA`),
powering conversational analytics in modeler.

## Current status

**Full history loaded: every season 1946-47 → 2025-26 (~72K games), pure-BR.** The daily
cron (`v2_daily.yml`) settles new games through the correct spine. Quarantine is empty;
all caveats carry human provenance; the audit is clean.

The data currently lives in `ZK_NBA_V2`; the `ZK_NBA_V2 → ZK_NBA` rename is the one
remaining (deliberate, deferred) step — see [`docs/REBUILD_PLAN.md`](docs/REBUILD_PLAN.md)
Phase 6.

> **History note:** this is a ground-up rebuild. The predecessor mashed an NBA-Stats
> snapshot (pre-2023) with BR scraping under one schema; that seam caused a real query
> failure. The rebuild is **one source end-to-end** — see `docs/REBUILD_METHOD.md` for the
> why. (The original V1 plan, `docs/plan.md`, is retained as history.)

## Architecture in one breath

`FLAT` relational tables are the queryable surface; `DERIVED` holds coverage-aware views.
No RAW tier (flattening happens in Python, not Snowflake) and no analytics tier — the
modeler agent computes at query time. Every game flows through one Python spine
(`src/nba_ingest/v2/slice.py`): **enumerate → fetch (BR) → flatten → guard → admit or
quarantine.** BR's own slugs are the join keys. A strict guardrail quarantines anything
flagged (never admit-on-caveat), and three exception ledgers
(`quarantine`/`data_caveats`/`audit_findings`) mean no record ever sits in limbo.

**→ Start with [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** for the full architecture,
patterns, and how-to.

## Documentation map

| Doc | What |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | **Onboarding** — data model, the spine, guardrail, ledgers, principles, common tasks |
| [`docs/REBUILD_METHOD.md`](docs/REBUILD_METHOD.md) | The *why* — values, design decisions, the per-phase contract |
| [`docs/REBUILD_PLAN.md`](docs/REBUILD_PLAN.md) | Phase-by-phase history, reflections, deferred backlog, cutover TODO |
| [`docs/BR_DATA_CATALOG.md`](docs/BR_DATA_CATALOG.md) | Basketball-Reference page shapes, era boundaries, data quirks/findings |
| [`docs/SETUP.md`](docs/SETUP.md) | Step-by-step setup (bootstrap → backfill → daily) |
| [`docs/SHAPES.md`](docs/SHAPES.md) | BR page shapes & table IDs from the POC |

## Quickstart

```bash
cp .env.example .env          # fill SNOWFLAKE_PASSWORD (PAT)
pip install -e .
python dev/apply_sql.py sql/001_bootstrap.sql   # then the sql/v2/*.sql DDL — see SETUP
python dev/_load_season.py --season 2025         # smoke-load one season
python dev/_audit.py                             # surface anomalies
```

Source: Basketball-Reference only (per BR's data-sharing policy; see `LICENSES.md`).
NBA.com is explicitly **out** (TOS §9.vii prohibits database scraping).

## Friction journal

As we use modeler against this data, every "I wanted to do X but had to leave the app"
moment gets logged in `FRICTION.md` — load-bearing for the eventual writeback /
derived-concept features.

## Layout

```
src/nba_ingest/
  v2/slice.py          THE spine — build_game, guard, enumerate, ledgers, cup-tagging
  br_client.py         BR HTTP client + table parser (fetch + retry)
  fetchers/            one module per BR page type (extract only)
  flatteners/          pure page→row transforms (no I/O, unit-tested)
  jobs/weekly_meta.py  weekly team/draft metadata refresh
  snowflake_client.py  connection + insert helpers
dev/                   operational CLIs: _backfill, _load_season, _settle, _approve, _audit, apply_sql
sql/ , sql/v2/         bootstrap + the live FLAT/governance schema and migrations
docs/                  ARCHITECTURE · REBUILD_METHOD · REBUILD_PLAN · BR_DATA_CATALOG · SETUP · SHAPES
.github/workflows/     v2_backfill.yml · v2_daily.yml (active cron) · weekly_meta.yml
```
