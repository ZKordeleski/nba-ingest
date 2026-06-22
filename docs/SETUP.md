# Setup

One-time setup for running nba-ingest. The pipeline is **pure Basketball-Reference** —
there is no external seed; history is built by scraping BR through the shared spine.

> The live data currently sits in **`ZK_NBA_V2`** (the rename to `ZK_NBA` is the deferred
> cutover step — see `REBUILD_PLAN.md` Phase 6). Use `ZK_NBA_V2` as the database name
> until that rename happens. For the architecture and the tools referenced below, read
> [`ARCHITECTURE.md`](ARCHITECTURE.md) first.

---

## 1. Clone

```bash
git clone https://github.com/ZKordeleski/nba-ingest.git
cd nba-ingest
```

## 2. Snowflake auth

Auto-detected from env vars. For local dev, use a PAT (Programmatic Access Token).

**Generate a PAT in Snowsight:** avatar (bottom-left) → **My profile** → **Programmatic
access tokens** → **Generate new token** → copy it immediately (shown once). That value is
`SNOWFLAKE_PASSWORD`.

**Connection params (modeler team account):**
```
SNOWFLAKE_ACCOUNT=ndsoebe-rai_int_modeler_team_aws_us_west_2_consumer
SNOWFLAKE_USER=ZACK.KORDELESKI@RELATIONAL.AI
SNOWFLAKE_ROLE=DEVELOPER_ADMIN
SNOWFLAKE_WAREHOUSE=NBA_INGEST_WH      (created by 001_bootstrap.sql)
SNOWFLAKE_DATABASE=ZK_NBA_V2           (→ ZK_NBA after the cutover rename)
SNOWFLAKE_PASSWORD=<your PAT>
```

For CI/GHA, use key-pair auth for the service user (wow-ingest's `docs/SETUP.md §2b` has
the identical key-pair steps).

## 3. Local env + install

```bash
cp .env.example .env          # fill SNOWFLAKE_PASSWORD
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"       # Python 3.11+
```

## 4. Bootstrap the schema

Apply the DDL via `dev/apply_sql.py` (or paste into Snowsight). Order:

```bash
python dev/apply_sql.py sql/001_bootstrap.sql      # database, schemas (FLAT, DERIVED), warehouse
python dev/apply_sql.py sql/v2/010_ddl.sql         # FLAT core tables (games, player_box_*, line_scores, ...)
python dev/apply_sql.py sql/v2/020_metric_coverage_seed.sql   # era recording-ramp metadata
python dev/apply_sql.py sql/v2/030_phase2_ddl.sql  # playoff_series + extras
python dev/apply_sql.py sql/v2/050_caveats.sql     # data_caveats (+ 051 provenance)
python dev/apply_sql.py sql/v2/060_quarantine.sql  # quarantine worklist
python dev/apply_sql.py sql/v2/070_audit_findings.sql
python dev/apply_sql.py sql/v2/040_derived_views.sql
```
(The `0xx_test.sql` files are assertions you can run to confirm each migration.) Verify:
```sql
SHOW DATABASES LIKE 'ZK_NBA_V2';
SHOW SCHEMAS IN DATABASE ZK_NBA_V2;
SELECT table_name FROM ZK_NBA_V2.INFORMATION_SCHEMA.TABLES WHERE table_schema='FLAT';
```

## 5. Backfill history

All loading goes through the shared spine (`src/nba_ingest/v2/slice.py`): enumerate →
fetch → flatten → guard → admit/quarantine. Checkpoint skips already-loaded games, so runs
resume and re-runs are safe.

```bash
# one season (smoke), then ranges
python dev/_load_season.py --season 2025
python dev/_backfill.py --from 1947 --to 1959
```

For the full history, dispatch in chunks via GHA (the 6h job cap → ~3 seasons/chunk for
high-volume modern eras):
```bash
gh workflow run v2_backfill.yml -f from_season=2016 -f to_season=2018
```

**Gate each chunk before the next:** count vs the known schedule (watch for lockout/COVID
seasons and the NBA Cup Championship), line-score completeness, and adjudicate every
quarantine *per-game with documented evidence* via `dev/_approve.py`. Run `dev/_audit.py`
to surface anomalies. (See `ARCHITECTURE.md` §9 for the gate cadence.)

A season with no playoffs page yet (an in-progress current season, or BAA 1947-49) blocks
unless you pass `--approve-no-playoffs --reviewer <you> --note "<why>"` — a deliberate,
traceable override.

## 6. Daily ingest (the cron)

`dev/_settle.py` settles recent dates through the same spine; `v2_daily.yml` runs it daily.

```bash
python dev/_settle.py --days 2     # manual catch-up; safe to re-run
```

GHA secrets (5):
```bash
for s in SNOWFLAKE_ACCOUNT SNOWFLAKE_USER SNOWFLAKE_PASSWORD SNOWFLAKE_ROLE SNOWFLAKE_WAREHOUSE; do
  gh secret set $s -R ZKordeleski/nba-ingest
done
```
The `v2_daily.yml` schedule is **active** (09:00 UTC). Confirm a run via the Actions tab,
then check `SELECT MAX(game_date) FROM ZK_NBA_V2.FLAT.games`.

## 7. After the cutover rename

When `ZK_NBA_V2` is renamed to `ZK_NBA`, re-point `dev/_settle.py` and `v2_daily.yml` at
`ZK_NBA` (they reference `ZK_NBA_V2` by name) and update `SNOWFLAKE_DATABASE`. See
`REBUILD_PLAN.md` Phase 6.
