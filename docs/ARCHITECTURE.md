# NBA Ingest — Architecture & Onboarding

Read this first if you're picking up the pipeline. It's the map of *how the system is
built and how it thinks*. For the deeper design rationale and values, see
[`REBUILD_METHOD.md`](REBUILD_METHOD.md); for the phase-by-phase history and the
deferred backlog, [`REBUILD_PLAN.md`](REBUILD_PLAN.md); for Basketball-Reference page
shapes and quirks, [`BR_DATA_CATALOG.md`](BR_DATA_CATALOG.md).

---

## 1. What it is

A **pure-Basketball-Reference** rebuild of NBA history in Snowflake (`ZK_NBA`), powering
conversational analytics in modeler. One source, one semantic. The pipeline flattens in
Python and writes relational rows directly, so the surface is:

- **`FLAT`** — the flattened relational tables (the queryable data).
- **`DERIVED`** — coverage-aware views (the ledger views + era-scoped leaderboards),
  computed at query time.

There is **no RAW tier** (V1's VARIANT staging was dropped in the rebuild — flattening
happens in Python, not in Snowflake) and **no analytics tier** (the modeler agent computes
analysis at query time).

> **Why pure-BR?** The predecessor mashed an NBA-Stats snapshot (pre-2023) with BR
> scraping (2023+) under one schema. That seam caused the original failure (a Finals
> query missed) — a *schema-level* defect, not a data one. The rebuild's thesis: one
> source end-to-end makes the identity model coherent. See `REBUILD_METHOD.md` §why.

## 2. Identity model — BR slugs *are* the keys

Because there's one source, BR's own identifiers are the join keys everywhere — no
cross-source bridge:

| Entity | id = | example |
|---|---|---|
| game | BR boxscore slug `YYYYMMDD0TTT` | `202412170OKC` |
| team | BR abbreviation | `OKC`, `BOS`, `BAA`-era `STB` |
| player | BR player slug | `gilgesh01` |
| official | BR official slug | — |

`league_for(season)` → `"BAA"` if season ≤ 1949 else `"NBA"` (the BAA predates the 1949
merger and lives under BR's `BAA_` URL prefix). Season = end-year (2025 = 2024-25).

## 3. The data model (`FLAT`)

**Core grain** (the data):
- `games` — one row per game; carries `season`, `season_type`, `round`, scores, team box
  totals, arena, `series_slug`. `ROUND`/`GAME_DATE`/`SEASON_TYPE` are first-class so
  questions like "Finals this week" are a filter, not a join.
- `player_box_basic` / `player_box_advanced` — player-game grain.
- `line_scores` — per-period points (wide: q1-4, ot1-6, ×2). *(A normalized
  `line_score_periods` table is a tracked backlog item — the wide shape is the
  repeating-groups anti-pattern, but complete for NBA history at 6 OT max.)*
- `game_officials`, `game_inactives`, `playoff_series`.

**Governance** (how we stay honest):
- `metric_coverage` — per-(metric, season) recording ramps: which stats existed when
  (e.g. line-score quarters: 1947≈74% → ~full by the 60s). Era-awareness lives here.
- The **three exception ledgers** (§6).

## 4. The ingest spine

Every game — historical or daily — flows through **one shared module**,
`src/nba_ingest/v2/slice.py`:

```
enumerate (which games?) → fetch (BR page) → flatten (page → rows)
   → guard (any problem?) → admit  ──or──  quarantine
```

- **`build_game(slug, season, series)`** is the spine: it fetches, flattens, sets
  `season_type`/`round`, runs `guard()`, and returns either the row buckets (clean) or a
  quarantine row (flagged). Same code for backfill and daily — so a fix lands everywhere.
- **Enumeration is index-driven**: `enumerate_season_by_schedule` reads the months a
  season *actually has* from its BR schedule index, rather than assuming an Oct–June
  window. This is why the 2020 Orlando bubble (Jul–Oct) and 2021's July Finals are
  captured — a hardcoded window silently dropped them. *(Read the source's shape; don't
  encode a belief about it.)*
- **Checkpoint**: loaders skip `game_id`s already in `games`, so any run resumes and
  re-running is a safe no-op. The DB *is* the progress ledger.
- **Post-load**: `tag_cup_championship(season)` re-tags the one NBA Cup game that
  doesn't count (§8).

**Entry points** (all on the same spine):

| Tool | Scope | Used by |
|---|---|---|
| `dev/_backfill.py` | a season *range* | `v2_backfill.yml` (manual, chunked) |
| `dev/_load_season.py` | one season | the backfill |
| `dev/_settle.py` | recent *dates* | `v2_daily.yml` (**active daily cron**) |

## 5. The guardrail — strict and binary

The load is **binary: clean → admit; ANY flag → quarantine.** There is *no*
admit-on-caveat at ingest. `guard()` returns a list of `issues`; `build_game(approve=
False)` quarantines on any issue and writes **no** caveat.

A caveat is written **only** by the human-driven `dev/_approve.py`
(`build_game(approve=True)`), which re-admits a *reviewed* game and records its issues
with provenance. So a `data_caveats` row means exactly: *"a named human approved this
game on this date, knowing this specific imperfection, for this reason."*

**Guards don't auto-loosen.** A flagged game always routes to human review; we never
auto-admit or auto-learn an exception. Loosening a guard is a deliberate human decision.

## 6. The three exception ledgers

Every imperfection lands in exactly one ledger by *disposition* — the system is
self-aware about its own gaps:

| Ledger | Disposition | Written by | Lifecycle |
|---|---|---|---|
| `quarantine` | **excluded**, held for review | the guard, automatically | drains on successful (re)load |
| `data_caveats` | **included-but-flagged** | `dev/_approve.py` (human) | permanent; carries `reviewed_by`/`reviewed_at`/`review_note` |
| `audit_findings` | **pending judgment** | `dev/_audit.py` | resolved/approved as adjudicated |

The invariant: 0 games sit in limbo. Every edge case is either excluded (quarantine),
admitted with a receipt (caveat), or queued for a decision (finding).

## 7. Principles to internalize

These are the patterns that keep the data trustworthy. They've each been earned the hard
way (the stories are in `REBUILD_PLAN`/`BR_DATA_CATALOG`):

- **NULL means not-recorded, never 0.** A DNP player, an unrecorded early-era stat → NULL.
  A coerced 0 is invisible to per-record checks and poisons aggregates.
- **Evidence over assumption.** State the *observation*, never an assumed cause. When BR
  contradicts itself, an **independent source** settles it — internal majority-vote of one
  source's own fields is unsafe (its errors are correlated).
- **Coverage ≠ validity.** "Every record valid" and "every record present" are different
  guarantees; a coverage gap hides inside per-record perfection. Verify counts against a
  *known expected shape* (schedule, roster), not just per-record integrity.
- **Era-awareness via `metric_coverage`.** A stat that didn't exist in 1955 being NULL is a
  documented *ramp*, not an anomaly — detectors scope to it so they flag real problems only.

## 8. Era & edge-case knowledge (hard-won)

- **BAA / early NBA (≤~1955):** sparse, hand-curated line scores (incomplete quarters but
  corroborated finals); minutes often unrecorded. Documented as coverage ramps, not bugs.
- **Lockouts & COVID:** 1999 (50-game), 2012 (66-game), 2020 (bubble, Jul–Oct, dual
  October), 2021 (72-game, July Finals). Validate counts against the *known* schedule, not
  a fixed 1,230.
- **NBA Cup Championship:** the *only* tournament game excluded from regular-season
  stats/standings (group/knockout/semifinals all count). Auto-detected via BR's "NBA Cup"
  scorebox label as the *single game on the latest Cup date* (semifinals share the label),
  tagged `season_type='NBA Cup Championship'`.
- **DNP / inactive players:** listed with NULL stats (not 0). The discriminator is
  `minutes_played`, never the 0-ness of a stat (real 0s — played, scored 0 — exist).
- **`player_id` collisions:** two distinct same-name players can share a resolved BR slug
  (two Chris Johnsons, 2013; two George Johnsons on opposing teams, 1973). We do *not*
  dedup (drops a real player); verified-distinct → admit-with-caveat. Per-row slug
  resolution is backlogged.
- **Transient fetch errors:** retried (`_fetch_retry`: ConnectionError/Timeout/5xx);
  `fetch_error` quarantines auto-retry on the next run (they're not a data judgment).

## 9. The audit & gate cadence

`dev/_audit.py` is the systematic anomaly surfacer (the answer to survivor bias — it looks
for what *should* be there and isn't). Detectors: uniqueness, reconciliation (line/box/
final cross-checks), profile null-rate jumps, line-score completeness, caveat-rate
proliferation. Findings persist to `audit_findings`; known phenomena (ramps, signed
caveats) are suppressed so flags are actionable.

**The loop** (per backfill chunk, and the model for any bulk load): load → **gate**
(count-vs-known-schedule + line-score completeness + adjudicate every quarantine
*per-game with documented evidence*) → next chunk. Internal validity is necessary but not
sufficient — always check coverage against an expectation.

## 10. Common tasks

```bash
# one-time: env + install
cp .env.example .env   # fill SNOWFLAKE_PASSWORD (PAT)
pip install -e .

# apply a schema migration
python dev/apply_sql.py sql/v2/010_ddl.sql

# backfill a season / range (chunk modern eras ~3 seasons for the 6h GHA cap)
python dev/_load_season.py --season 1973          # one season
python dev/_backfill.py --from 2016 --to 2018     # a range
gh workflow run v2_backfill.yml -f from_season=2016 -f to_season=2018   # via GHA

# daily settle (also the cron); checkpoint => safe re-run
python dev/_settle.py --days 2

# review the quarantine worklist, then admit a real-but-imperfect game with provenance
python dev/_approve.py --game <id> --reviewer <you> --note "<evidenced rationale>"   # --apply to execute

# surface anomalies
python dev/_audit.py
```

Adjudication is always **per-game with documented evidence** — never a bulk assumption
about a class. Corroborate against an independent source where the call is non-obvious.

## 11. Where things live

```
src/nba_ingest/
  v2/slice.py          THE spine: build_game, guard, enumerate, tag_cup_championship, ledgers
  br_client.py         BR HTTP client + table parser (fetch + _fetch_retry)
  fetchers/            one module per BR page type (extract only): games, boxscore, schedule, draft
  flatteners/          pure page→row transforms (no I/O, unit-tested)
  jobs/weekly_meta.py  weekly team/draft metadata refresh (the one surviving scheduled job module)
  snowflake_client.py  connection + insert/PUT helpers
dev/                   operational tooling (the V2 spine's CLIs — see §10)
  _backfill.py _load_season.py _settle.py _approve.py _audit.py apply_sql.py
  _remediate_*.py      one-time/maintenance (see each file's telos docstring)
sql/                   001_bootstrap (db/schemas/warehouse), 0x0 raw/flat DDL
sql/v2/                the live schema: 010_ddl, 020_metric_coverage_seed, 050_caveats,
                       060_quarantine, 070_audit_findings, + migrations & *_test.sql
docs/                  ARCHITECTURE (this) · REBUILD_METHOD (why/values) · REBUILD_PLAN
                       (history+backlog) · BR_DATA_CATALOG (BR shapes) · SETUP · SHAPES
.github/workflows/     v2_backfill.yml · v2_daily.yml (active cron) · weekly_meta.yml
```

## 12. Cutover status

The data lives in `ZK_NBA_V2` and is the **actively-maintained** DB (the daily cron writes
to it through the correct spine). The final step — `DROP ZK_NBA; RENAME ZK_NBA_V2 → ZK_NBA`
— is deliberately deferred; it's a pure name-swap now that the pipeline is correct. See
`REBUILD_PLAN.md` Phase 6 for the standing TODO (and the one carry-forward: re-point
`_settle.py`/`v2_daily.yml` at the renamed DB).
