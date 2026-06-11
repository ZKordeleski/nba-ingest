"""Phase 4 full historical backfill — loop seasons through the checkpoint-resumable
season loader. Each season runs in its own subprocess so one failure can't abort
the range, and the per-season checkpoint means re-running resumes (skips loaded
games). Designed to run in GHA decade-chunks under the 6h job limit.

Usage:
    .venv/bin/python dev/_backfill.py --from 1947 --to 2025
    .venv/bin/python dev/_backfill.py --from 1970 --to 1979   # one decade (a GHA chunk)

After a chunk completes, run dev/_audit.py to surface any new era anomaly.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).parent.parent
LOADER = REPO / "dev" / "_load_season.py"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="start", type=int, required=True, help="first season end-year")
    ap.add_argument("--to", dest="end", type=int, required=True, help="last season end-year (inclusive)")
    args = ap.parse_args()

    seasons = list(range(args.start, args.end + 1))
    print(f"BACKFILL seasons {seasons[0]}..{seasons[-1]} ({len(seasons)} seasons)\n")
    summary = []
    for season in seasons:
        print(f"\n================ season {season} ================", flush=True)
        # Subprocess isolation: a season that errors hard doesn't kill the range;
        # the next run resumes it via the loader's per-season checkpoint.
        # NOTE: never pass --approve-no-playoffs here — the automated backfill must
        # not approve anomalous seasons. A season missing its playoffs page exits
        # rc=2 (needs human review); a human approves it separately via
        # dev/_load_season.py --season N --approve-no-playoffs.
        rc = subprocess.run([sys.executable, str(LOADER), "--season", str(season)],
                            cwd=str(REPO)).returncode
        summary.append((season, rc))
        if rc == 2:
            print(f"!! season {season} BLOCKED (rc=2) — needs human review (see audit_findings)", flush=True)
        elif rc != 0:
            print(f"!! season {season} exited rc={rc} — continuing (resume on next run)", flush=True)

    print("\n================ BACKFILL SUMMARY ================")
    for season, rc in summary:
        tag = "ok" if rc == 0 else ("NEEDS REVIEW" if rc == 2 else f"rc={rc}")
        print(f"  {season}: {tag}")
    review = [s for s, rc in summary if rc == 2]
    failed = [s for s, rc in summary if rc not in (0, 2)]
    clean = len(seasons) - len(review) - len(failed)
    print(f"\n{clean}/{len(seasons)} seasons clean.")
    if review:
        print(f"  NEEDS HUMAN REVIEW (missing playoffs page): {review} — review audit_findings, "
              f"then load each with dev/_load_season.py --season N --approve-no-playoffs")
    if failed:
        print(f"  Re-run to resume (transient/parse failures): {failed}")
    if not review and not failed:
        print("  Run dev/_audit.py next.")
    return 1 if (failed or review) else 0


if __name__ == "__main__":
    sys.exit(main())
