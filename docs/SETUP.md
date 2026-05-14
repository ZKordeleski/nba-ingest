# Setup

One-time setup for running nba-ingest. Expect ~30 minutes the first time (Snowflake bootstrap + JB seed queries take a few minutes to execute).

---

## 1. Clone the repo

```bash
git clone https://github.com/ZKordeleski/nba-ingest.git
cd nba-ingest
```

---

## 2. Set up Snowflake

### 2a. Auth method

This pipeline supports two auth methods, auto-detected from env vars. For local dev against your own Snowflake user, use a PAT (Programmatic Access Token).

**To generate a PAT in Snowsight:**
1. Click your user avatar (bottom-left) -> **My profile**.
2. Scroll to **Programmatic access tokens** -> **Generate new token**.
3. Give it a name (e.g. `nba-ingest-local`), pick an expiry, generate.
4. Copy the token immediately — it's shown once.

That value goes in `SNOWFLAKE_PASSWORD` in your `.env`.

**Connection params for the modeler team account:**
```
SNOWFLAKE_ACCOUNT=ndsoebe-rai_int_modeler_team_aws_us_west_2_consumer
SNOWFLAKE_USER=ZACK.KORDELESKI@RELATIONAL.AI
SNOWFLAKE_ROLE=DEVELOPER_ADMIN
SNOWFLAKE_WAREHOUSE=NBA_INGEST_WH  (after running 001_bootstrap.sql)
SNOWFLAKE_DATABASE=ZK_NBA
SNOWFLAKE_PASSWORD=<your PAT>
```

### 2b. Key-pair auth (for CI / GHA)

If setting up GitHub Actions, use key-pair auth for the service user instead of a PAT. See wow-ingest's `docs/SETUP.md §2b` for the key-pair generation steps — identical process.

---

## 3. Run Snowflake bootstrap

Open Snowsight or use SnowSQL. Run each SQL file in order:

```bash
# Or run manually via Snowsight — paste and execute each file

# Step 1: Create database, schemas, warehouse
# Apply sql/001_bootstrap.sql

# Step 2: Create RAW tables
# Apply sql/020_raw_tables.sql

# Step 3: Create FLAT tables
# Apply sql/040_flat_tables.sql
```

Verify:
```sql
SHOW DATABASES LIKE 'ZK_NBA';
SHOW SCHEMAS IN DATABASE ZK_NBA;
SHOW WAREHOUSES LIKE 'NBA_INGEST_WH';
```

---

## 4. Configure .env

```bash
cp .env.example .env
# Edit .env and fill in SNOWFLAKE_PASSWORD with your PAT
```

---

## 5. Install Python dependencies

```bash
pip install -e ".[dev]"
```

Requires Python 3.11+. Recommend using a virtual environment:
```bash
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

---

## 6. Run Slice 1 seeding

The seed scripts pull from `JB_HISTORIC_NBA.PUBLIC` (same Snowflake account) into `ZK_NBA.FLAT`. Run them in order via Snowsight:

```
sql/050_seed_from_jb/001_player_box.sql     (~1.6M rows, ~30-60s)
sql/050_seed_from_jb/002_games.sql          (~65K rows)
sql/050_seed_from_jb/003_line_scores.sql    (~58K rows)
sql/050_seed_from_jb/004_officials.sql      (~71K rows)
sql/050_seed_from_jb/005_players.sql        (~6.5K rows)
sql/050_seed_from_jb/006_teams.sql          (30 rows, 5 nulls expected)
sql/050_seed_from_jb/007_draft.sql          (~8K rows)
sql/050_seed_from_jb/008_inactive.sql       (~110K rows)
sql/050_seed_from_jb/009_draft_combine.sql  (~1.2K rows)
sql/050_seed_from_jb/010_team_history.sql   (~140 rows)
sql/050_seed_from_jb/011_play_by_play.sql   (~2.4M rows, may take 1-2 min)
```

After `006_teams.sql`, manually fill the 5 missing TEAM_DETAILS entries for ORL, NYK, BOS, CLE, NOP from BR team pages:
- https://www.basketball-reference.com/teams/ORL/
- https://www.basketball-reference.com/teams/NYK/
- https://www.basketball-reference.com/teams/BOS/
- https://www.basketball-reference.com/teams/CLE/
- https://www.basketball-reference.com/teams/NOP/

After seeding all 11 files, run the DRAFT_COMBINE_STATS DESCRIBE first to confirm column names match what `009_draft_combine.sql` expects:
```sql
DESCRIBE TABLE JB_HISTORIC_NBA.PUBLIC.DRAFT_COMBINE_STATS;
```

---

## 7. Validate Slice 1

Run each validation file and compare against expected values in the comments:

```
sql/090_validation/001_row_counts.sql
sql/090_validation/002_date_ranges.sql
sql/090_validation/003_spot_checks.sql
sql/090_validation/004_linkage_checks.sql
```

---

## 8. Run Slice 2 backfill (BR scraper)

Run the backfill one season at a time. Each season takes ~25-30 min at 3s crawl-delay:

```bash
BACKFILL_SEASON=2023-24 python -m nba_ingest.jobs.backfill
BACKFILL_SEASON=2024-25 python -m nba_ingest.jobs.backfill
```

For the current ongoing season, run daily_settle to catch up from the last backfill date to today:
```bash
# Override date for each day you need to catch up
SETTLE_DATE=2025-10-01 python -m nba_ingest.jobs.daily_settle
# ... repeat for each date, or run backfill for current season
```

---

## 9. Configure GHA secrets

Set the 5 required secrets in the GitHub repo:

```bash
gh secret set SNOWFLAKE_ACCOUNT -R ZKordeleski/nba-ingest
gh secret set SNOWFLAKE_USER -R ZKordeleski/nba-ingest
gh secret set SNOWFLAKE_PASSWORD -R ZKordeleski/nba-ingest
gh secret set SNOWFLAKE_ROLE -R ZKordeleski/nba-ingest
gh secret set SNOWFLAKE_WAREHOUSE -R ZKordeleski/nba-ingest
```

Test with a manual dispatch before enabling the cron:
```bash
gh workflow run daily_settle.yml -R ZKordeleski/nba-ingest \
  -f settle_date=$(date -d "yesterday" +%Y-%m-%d)
```

---

## 10. Enable workflows

Once the manual dispatch above succeeds:

1. Uncomment the `schedule:` block in `.github/workflows/daily_settle.yml`.
2. Commit and push.
3. Confirm the next scheduled run fires via GHA Actions tab.
4. Check `SELECT MAX(game_date) FROM ZK_NBA.FLAT.games` the morning after to confirm a row landed.
