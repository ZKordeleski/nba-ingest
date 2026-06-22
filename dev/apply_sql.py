"""Apply a SQL file to ZK_NBA.

Uses MULTI_STATEMENT_COUNT=0 so Snowflake's parser splits statements itself —
handles BEGIN...END Scripting blocks and inline -- comments correctly.

Usage:
    python dev/apply_sql.py sql/001_bootstrap.sql
    python dev/apply_sql.py sql/v2/054_line_score_ot56.sql
"""

from __future__ import annotations

import sys
from pathlib import Path

from dotenv import load_dotenv

# Load .env from the repo root (sibling of this dev/ directory).
load_dotenv(Path(__file__).parent.parent / ".env")

from nba_ingest.snowflake_client import connect


def apply_sql_file(path: Path) -> None:
    sql_text = path.read_text()
    print(f"applying {path} ({len(sql_text)} bytes)")
    conn = connect()
    try:
        cur = conn.cursor()
        try:
            cur.execute(sql_text, num_statements=0)
            while True:
                for row in cur.fetchall():
                    print("  ", row)
                if not cur.nextset():
                    break
        finally:
            cur.close()
    finally:
        conn.close()
    print(f"applied {path} ✓")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    apply_sql_file(Path(sys.argv[1]))
