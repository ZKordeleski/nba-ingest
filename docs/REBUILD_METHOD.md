# Rebuild Method & Design Decisions

**Companion to `REBUILD_PLAN.md`.** The plan says *what* we build, phase by phase. This doc says *how we work* and *why the hard design calls went the way they did*. Established 2026-06-08.

The rebuild's purpose, stated as a telos rather than a task: **make true basketball questions truthfully answerable, across the whole history of the league, from a single trustworthy source.** Every decision below serves that end. When a choice doesn't, we stop and revisit — we don't route around our own goals.

---

## 1. How we work — the per-phase contract

We work in vertical slices (per `REBUILD_PLAN.md`), but each slice is governed by a teleological, test-first, mastery-based contract. The discipline: **we only believe something works if we can test it, and the test is written before the work.**

### Phase charter (write before any code)

Every phase opens with a charter:

- **Telos** — what this phase is *for*, in basketball + data terms. Not "ingest the games table" but "make *this class of basketball question* answerable, and provably true." The telos names the questions a fan would ask.
- **Definition of success** — an explicit rubric. Pass/fail criteria, not a vibe. What must be true for us to call this done.
- **The test** — an *executable* check that proves the rubric. SQL assertions **plus at least one basketball-truth spot-check** — a fact a knowledgeable fan would recognize (e.g., "the 2023 Finals G5 row is identifiable as a *Finals* game and shows DEN 94, MIA 89"). Written first, so the goalposts can't move.

> **Why the basketball spot-check is non-negotiable.** A row-count test passes on a broken DB — the V1 database had 104K modern player-games land cleanly and *still* couldn't find the Finals. Only a basketball question exposed the lie. Every phase test carries at least one "would a fan recognize this as true?" assertion. Data-arrival tests are necessary, never sufficient.

### Phase close (run before moving on)

Every phase closes with:

1. **Run the test** — pass/fail, with the actual output pasted in. No "looks done."
2. **Reflect against goals and values** — what's working, what's weak. Did we hit a wall and *solve* it, or quietly route around it? If a pivot would diverge from our values (single-source, domain-grounding, fail-loud, no-shortcuts), we **stop and raise it** rather than compromise silently.
3. **Favors for future-us** — a concrete list of things we left better than we found them: a column comment written, a guard added, a breakpoint documented, a gnarly query made trivial by a view. The `metric_coverage` registry (§3) is the canonical favor.

The reflection is appended to `REBUILD_PLAN.md` as a dated `## Phase N Reflection` section — the same load-bearing-history pattern that makes `HANDOFF.md` useful.

### Documentation phase (at the end of the run)

After the build, a dedicated **"distill to persistent documentation"** phase takes this method doc + the plan + the *actual* results and distills them into durable docs (schema reference, agent-facing query guide, the coverage story). The build artifacts are the rough draft; that phase produces the clean record.

---

## 2. Values (carried from `REBUILD_PLAN.md` principles, sharpened)

1. **Single source, no exceptions.** One source (Basketball-Reference), one `game_id` scheme, **zero cross-source joins, ever.** No back-seeding from another database. This is the root fix for the entire V1 source-mash post-mortem — the bug class cannot exist without a second source to reconcile against.
2. **Fail loud, never default-plausible.** A value that can't be sourced is NULL (a *failed mapping*) or a quarantined row — never a fabricated default that looks real. (See §4.)
3. **Grounded in basketball, not data for data's sake.** Every table and column maps to something real about the game. We model the sport's ontology, not the scraper's convenience. (See §5.)
4. **Metadata is a deliverable, not an afterthought.** Column comments and the coverage registry are read by the agent at query time and by humans forever. They get authored with care. (See §3, §6.)
5. **No shortcuts at walls.** When the scrape is hard or the data is messy, we own it and solve it. We stop only if solving it would betray a value above — and then we raise it, not bury it.

---

## 3. The evolving-data-availability problem (design decision)

**The problem.** Basketball data is not uniform across history. Two independent axes change over time:

- **What BR exposes** (from the Phase 0 era-boundary table): advanced box from 1985, per-quarter box from ~2010, anchored official links from 1995, no meta blocks at all for the earliest BAA games.
- **What the NBA ever tracked**: steals & blocks & the O/D rebound split begin 1973-74; turnovers 1977-78; the 3-pointer 1979-80. Before those, the stat *did not exist* — a NULL is not a zero.

A naive wide table with NULLs makes the agent draw false conclusions: *"Bill Russell had 0 steals," "there were no Finals before 2024."* This is the same failure as the FINALS miss — **a NULL or a missing distinction read as a fact.**

**We don't yet know all the breakpoints, or their exact shape.** Pinning them is explicit Phase 0 investigation work (see the action items). The architecture below is chosen to be *correct regardless of where the breakpoints land*, so investigation refines values in a table rather than forcing a schema migration.

### Three approaches considered

- **A — Era-partitioned schema.** A stat-column exists only in the era it was tracked (pre-1974 box has no `stl` column at all). *Pro:* impossible to query a stat that never existed. *Con:* every cross-era query becomes a union; the agent must know boundaries; moving a breakpoint means a schema migration. Breaks single-table simplicity.
- **B — Wide nullable table + column-level provenance metadata.** One wide table; NULL where absent; Snowflake column comments record `stl: tracked from 1973-74; NULL before = not recorded`. *Pro:* simple queries, one schema, plays to metadata-as-deliverable. *Con:* NULL is overloaded unless the agent actually reads the metadata — if it doesn't, false conclusions return.
- **C — Explicit capability/coverage dimension.** A first-class `metric_coverage` table — `(metric, season_range, status ∈ {tracked, not_tracked, partial})` — consulted by the agent or by guardrail views before aggregating. *Pro:* "not tracked" becomes un-ignorable; enables truthful narrative answers ("steals leaders *since 1973-74*"); aligns with fail-loud + ontology. *Con:* most upfront work; needs the breakpoints known.

### Distilled approach (best of each)

**B's single wide table** (query simplicity, one schema) **+ C's `metric_coverage` registry as the source of truth for interpretation**, surfaced *both* as rich Snowflake column comments *and* as a queryable table, *plus* guardrail views for the highest-risk leaderboard queries (career/all-time leaders, "firsts"). **Borrow A's honesty** — we never backfill fake zeros; where a stat never existed, the comment and the coverage row say so plainly — but **reject A's hard partitioning** as too costly and hostile to the single-table model.

> **The table-split rule (when separate tables ARE warranted):** split by **grain**, never by **era**. Different grain → different table (`player_box_basic` vs `player_quarter_box` vs `games`). Same grain across eras → the *same* table, with NULLs + `metric_coverage` for stats that era didn't track. Old box scores are not a different *shape* — BR's column template is uniform across eras (Phase 0); they're the same columns with more NULLs. Era-partitioned tables would re-introduce the cross-era-union pain and "agent must know the boundaries" problem — the exact fragmentation that made V1 a mess. *(Validated in Phase 3: 1972-73 dropped into the identical schema once a parse bug — inferring DNP from missing minutes — was fixed; both eras coexist in one table, proven by `092_phase3_test.sql` #9.)*

**The governing invariant — no ambiguous NULL.** Every NULL must resolve, via the coverage layer, to exactly one of:
- **not-tracked-this-era** — the stat didn't exist yet (interpret as "not applicable," never zero), or
- **tracked-but-missing-this-game** — a genuine gap that should be near-zero and is *flagged by the guard* (§4).

If we can't tell those two apart for a given NULL, the model is wrong and we fix it before shipping.

---

## 4. The bad-data / "unexpected result" guard (design decision)

Scraping is inherently lossy and brittle; we own that. The guard exists so a bad scrape **cannot flood FLAT with wrong data** — it fails loud and quarantines instead.

A validation gate sits between flatten and MERGE:

- **Structural drift detection (the most important).** If an expected table (`box-{TTT}-game-basic`) is missing from a page, that page **fails loudly** — it does *not* write empty rows. A page that yields zero usable rows is an **error, not a no-op.** This is the exact mechanism that birthed V1's `season_type` NULL: a stub that silently produced nothing. BR changing its HTML must break loudly, not corrupt quietly.
- **Basketball domain-range checks.** Grounded in the rules of the game: `fgm ≤ fga`, `fg3m ≤ fg3a`, `ftm ≤ fta`, `0 ≤ fg_pct ≤ 1`, `0 ≤ pts ≤ ~105` (Wilt's 100 is the ceiling), `minutes ∈ [0, ~70]` (allows 4-OT), `home_pts ≠ away_pts` (no ties in basketball), quarter/OT scores sum to the final, and player points reconcile to the team total within rounding.
- **Quarantine, don't poison.** Rows failing validation land in a `RAW.quarantine` table with the failure reason + source URL — never in FLAT. The job logs a quarantine count; a spike trips the gate (fail-loud).
- **Independent reconciliation.** The schedule page asserts N games on date D; if the box scrape produced ≠ N games, flag it. (This is Phase 5 parity logic, pulled forward as a *continuous* check, not just an end-gate.)
- **Idempotent MERGE** means re-running after a parser fix self-heals — no TRUNCATE, no collateral damage.

---

## 5. Basketball-domain ontology audit

The FINALS miss was one instance of a pattern: **a basketball-meaningful distinction collapsed into a coarse or absent column.** This audit catalogs the others so the rebuild models the sport, not the scraper. (Status filled as Phase 0 confirms each in BR's data.)

| Ontology gap | The basketball truth being lost | BR source |
|---|---|---|
| **Playoff round / series** (the FINALS miss) | A game isn't "a playoff game" — it's "Game 6 of the 2016 Finals, CLE down 3–1." Round, series, game-in-series, seeding. | `/playoffs/NBA_{year}.html` bracket + boxscore header |
| **Stat-category temporal availability** ⚠️ | Steals/blocks (1973-74), turnovers (1977-78), the 3-pointer (1979-80) didn't exist before their seasons. A NULL `stl` for Russell means *not recorded*, never "0 steals." | inherent to era; BR omits the columns |
| **Competition context** | Regular / Playoff / **Play-In** (2020+) / **NBA Cup** (2023+) / Preseason / All-Star are different games with different stakes — not interchangeable rows in one pile. | season-type + Cup pages |
| **Rule-era comparability** | "Most points in a game" / "best 3P%" is meaningless without the rule era (shot clock 1954, 3-line 1979, hand-check ban 2004, pace). | derived from season |
| **Franchise continuity** | Is the 2008 Sonics the "same team" as the 2009 Thunder? Does the current Hornets own the 1988–2002 history? (Genuinely contested — a basketball-knowledge call, not a join.) | franchise pages + domain judgment |
| **DNP semantics** | "Rest" / "load management" is a 2010s+ phenomenon; "G-League assignment" is modern. NULL minutes loses the *why*. | inactive meta block |

⚠️ **Stat-category availability is both the FINALS bug and the evolving-availability problem at once** — and it's the most dangerous, because the agent will confidently fabricate ("Russell: 0 steals"). It is now a first-class concern, addressed by the `metric_coverage` registry (§3).

---

## 6. Metadata as a deliverable

Snowflake column comments and the `metric_coverage` table are written *for the agent at query time and for humans forever*:

- Every column comment is **source-traceable and era-aware**: what BR page it comes from, and any era caveats ("anchored official links only from 1995; bare names before").
- The comment must reflect what the code **actually does**, not the intended design — V1's comments vouched for a `LEFT(game_id,1)` derivation that could never fire. In the rebuild, comments are checked against behavior.
- `metric_coverage` is the single queryable source of truth for "what can this dataset truthfully answer for this era," and the canonical favor-to-future-us.

---

## 7. The audit: systematic anomaly surfacing (the survivor-bias answer)

Loud-failing (the guard) catches *missing/impossible* data; it cannot catch a *plausible-but-wrong belief* baked into data that loads cleanly (Phase 3's cliff-vs-ramp). And we cannot pre-enumerate every pitfall — survivor bias *is* the unknown-unknowns. The answer is neither exhaustive manual checking (infinite) nor pre-abstracting every pitfall (impossible); it's to **systematize the *detection of anomaly classes*, not the prediction of instances.**

`dev/_audit.py` runs generic detectors over every table and season for the classes we keep hitting:
- **uniqueness** (PK dupes — the George-Johnson collision), **reconciliation** (box vs team, line-score quarters vs final, line vs games), **range** (basketball domain bounds), **referential** (orphans, 2 teams/game)
- **profile** — per-column null-rate by season; an *era-boundary jump* is the cliff/ramp signal; *all-null* is a dead column
- **coverage** — data that contradicts `metric_coverage`'s own claims

The leverage: **the system finds; we judge.** Adjudications are encoded back into `metric_coverage` (ramp vs cliff boundaries), so the audit **auto-suppresses what we've already explained and only escalates genuine surprises** — it *converges* instead of treadmilling. Proven: coverage-aware suppression took a run from 30 flags to 3, each real. "Did we miss something?" becomes "are there unexplained flags?" — a one-line answer.

**Standing gate:** run the audit after every load (Phase 4+) and as a post-cutover health check. Any new flag must be adjudicated — *expected* → record the boundary in `metric_coverage`; *bug* → fix in the flattener and apply at the next reload. Floor: this catches structural/distributional errors; a plausible-and-internally-consistent wrong value (a BR typo) needs the agent-harness golden-truth tests as backstop.

## 8. Where this connects

- Phased roadmap, slice definitions, data inventory: `REBUILD_PLAN.md`
- V1 failure evidence that motivates all of the above: `REBUILD_PLAN.md` → "V1 source-mash post-mortem"
- What BR actually exposes per era (the empirical ground truth): `docs/BR_DATA_CATALOG.md`
