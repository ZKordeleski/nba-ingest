"""Phase 1 slice orchestrator: DEN 2024-25 -> ZK_NBA_V2. Single source (BR).

Per REBUILD_METHOD.md: fetch each game once, flatten to V2 rows, run the bad-data
guard (fail-loud on structural drift, basketball domain-range checks,
quarantine-not-poison), then load. Plus the 2025 playoff bracket -> playoff_series
and round/game_in_series tagging from each playoff boxscore's <h1>.

Usage:
    .venv/bin/python dev/_phase1_slice.py --limit 3   # smoke test on N games
    .venv/bin/python dev/_phase1_slice.py             # full DEN 2024-25
"""

from __future__ import annotations

import argparse
import logging
import re
import sys
from pathlib import Path

from bs4 import BeautifulSoup
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

from nba_ingest.br_client import (
    BASE_URL,
    extract_game_slugs_from_html,
    fetch,
    parse_tables_with_comments,
)
from nba_ingest.fetchers.boxscore import _extract_player_anchors, _find_team_abbrs_from_tables
from nba_ingest.flatteners.boxscore import (
    _drop_totals_row,
    _extract_team_totals,
    _flatten_columns,
    _now_utc,
    _parse_minutes,
    _safe_float,
    _safe_int,
    flatten_game_row,
    flatten_line_score,
)
from nba_ingest.snowflake_client import connect

logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(message)s")
log = logging.getLogger("phase1")
log.setLevel(logging.INFO)

SEASON = 2025
TEAM = "DEN"
TEAM_NICK = "nuggets"  # for matching DEN's series in the bracket slug (this slice)

CANONICAL_ROUNDS = [  # check longest/most-specific first
    ("Conference Semifinals", "Conference Semifinals"),
    ("Conference Finals", "Conference Finals"),
    ("First Round", "First Round"),
    ("Play-In", "Play-In"),
    ("Finals", "Finals"),  # last — substring of "Conference Finals"
]


# ───────────────────────────────────────────────────────── parsing helpers
def parse_round_from_h1(h1: str) -> tuple[str, str | None, int | None]:
    """(season_type, round, game_in_series) from a boxscore <h1>.

    Regular-season h1s have no round phrase -> ('Regular Season', None, None).
    """
    for needle, canon in CANONICAL_ROUNDS:
        if needle.lower() in h1.lower():
            gm = re.search(r"Game (\d+)", h1)
            season_type = "Play-In" if canon == "Play-In" else "Playoffs"
            return season_type, canon, (int(gm.group(1)) if gm else None)
    return "Regular Season", None, None


def parse_arena(soup: BeautifulSoup) -> tuple[str | None, str | None, str | None]:
    """Arena/city/state from scorebox_meta (pipe-delimited; venue is segment 2)."""
    meta = soup.find("div", class_="scorebox_meta")
    if not meta:
        return None, None, None
    segs = [s.strip() for s in meta.get_text("|").split("|") if s.strip()]
    # The venue segment looks like "Ball Arena, Denver, Colorado" and is not the
    # date/time segment (which contains AM/PM). Pick the first qualifying one.
    for seg in segs:
        if ("AM" in seg or "PM" in seg) and re.search(r"\d{4}", seg):
            continue  # date/time segment
        parts = [p.strip() for p in seg.split(",")]
        if len(parts) >= 2:
            name = parts[0]
            city = parts[1] if len(parts) >= 2 else None
            state = parts[2] if len(parts) >= 3 else None
            return name, city, state
    return None, None, None


def _starters(basic_df) -> set[str]:
    """Player names appearing above the 'Reserves' separator (the starters)."""
    df = _flatten_columns(basic_df.copy())
    col = df.columns[0]
    out: set[str] = set()
    for val in df[col]:
        s = str(val).strip()
        if s == "Reserves":
            break
        if s and s not in ("Starters", "nan") and "Team Totals" not in s:
            out.add(s)
    return out


# ───────────────────────────────────────────────────────── flatteners (V2)
def flatten_basic_v2(slug, team_abbr, df, is_home, is_win, season_type, anchors):
    if df is None or df.empty:
        return []
    starters = _starters(df)
    d = _drop_totals_row(_flatten_columns(df.copy()))
    rows = []
    for _, r in d.iterrows():
        name = str(r.get("Player", r.iloc[0])).strip()
        mp = _parse_minutes(r.get("MP"))
        dnp = mp is None
        _i = lambda v: 0 if dnp else _safe_int(v)
        rows.append({
            "game_id": slug,
            "player_id": anchors.get(name) or name,
            "player_name": name,
            "team_abbr": team_abbr,
            "is_home": is_home,
            "is_starter": name in starters,
            "is_win": is_win,
            "season": SEASON,
            "season_type": season_type,
            "minutes_played": mp,
            "pts": _i(r.get("PTS")), "ast": _i(r.get("AST")), "reb": _i(r.get("TRB")),
            "oreb": _i(r.get("ORB")), "dreb": _i(r.get("DRB")), "stl": _i(r.get("STL")),
            "blk": _i(r.get("BLK")), "tov": _i(r.get("TOV")), "pf": _i(r.get("PF")),
            "fgm": _i(r.get("FG")), "fga": _i(r.get("FGA")), "fg_pct": _safe_float(r.get("FG%")),
            "fg3m": _i(r.get("3P")), "fg3a": _i(r.get("3PA")), "fg3_pct": _safe_float(r.get("3P%")),
            "ftm": _i(r.get("FT")), "fta": _i(r.get("FTA")), "ft_pct": _safe_float(r.get("FT%")),
            "plus_minus": _safe_float(r.get("+/-")),
            "game_score": _safe_float(r.get("GmSc")),
            "fetched_at": _now_utc(),
        })
    return rows


def flatten_advanced_v2(slug, df, anchors):
    if df is None or df.empty:
        return []
    d = _drop_totals_row(_flatten_columns(df.copy()))
    rows = []
    for _, r in d.iterrows():
        name = str(r.get("Player", r.iloc[0])).strip()
        rows.append({
            "game_id": slug, "player_id": anchors.get(name) or name,
            "ts_pct": _safe_float(r.get("TS%")), "efg_pct": _safe_float(r.get("eFG%")),
            "fg3a_rate": _safe_float(r.get("3PAr")), "fta_rate": _safe_float(r.get("FTr")),
            "orb_pct": _safe_float(r.get("ORB%")), "drb_pct": _safe_float(r.get("DRB%")),
            "trb_pct": _safe_float(r.get("TRB%")), "ast_pct": _safe_float(r.get("AST%")),
            "stl_pct": _safe_float(r.get("STL%")), "blk_pct": _safe_float(r.get("BLK%")),
            "tov_pct": _safe_float(r.get("TOV%")), "usg_pct": _safe_float(r.get("USG%")),
            "ortg": _safe_int(r.get("ORtg")), "drtg": _safe_int(r.get("DRtg")),
            "bpm": _safe_float(r.get("BPM")), "fetched_at": _now_utc(),
        })
    return rows


# ───────────────────────────────────────────────────────── the bad-data guard
def guard(game_row, basic_rows) -> list[str]:
    """Return a list of violations. Empty list = clean. Basketball domain ranges."""
    v = []
    hp, ap = game_row["home_pts"], game_row["away_pts"]
    if hp is None or ap is None:
        v.append("missing team points")
    elif hp == ap:
        v.append(f"tie game ({hp}={ap}) — impossible in NBA")
    for r in basic_rows:
        who = f"{r['player_name']}"
        for made, att in (("fgm", "fga"), ("fg3m", "fg3a"), ("ftm", "fta")):
            if r[made] is not None and r[att] is not None and r[made] > r[att]:
                v.append(f"{who}: {made}>{att} ({r[made]}>{r[att]})")
        if r["pts"] is not None and not (0 <= r["pts"] <= 105):
            v.append(f"{who}: pts out of range ({r['pts']})")
        if r["fg_pct"] is not None and not (0 <= r["fg_pct"] <= 1):
            v.append(f"{who}: fg_pct out of range ({r['fg_pct']})")
    # team-total reconciliation: sum of player pts per team == team box total
    for abbr, total in ((game_row["home_team_abbr"], hp), (game_row["away_team_abbr"], ap)):
        s = sum(r["pts"] or 0 for r in basic_rows if r["team_abbr"] == abbr)
        if total is not None and s != total:
            v.append(f"{abbr}: player-pts sum {s} != team total {total}")
    return v


# ───────────────────────────────────────────────────────── bracket
def fetch_playoff_series() -> list[dict]:
    """Parse /playoffs/NBA_{SEASON}.html into playoff_series rows."""
    html = fetch(f"{BASE_URL}/playoffs/NBA_{SEASON}.html")
    slugs = sorted(set(re.findall(rf"/playoffs/({SEASON}-nba-[a-z0-9-]+)\.html", html)))
    rows = []
    for s in slugs:
        round_, seq, conf = None, None, None
        if "conference-semifinals" in s or re.search(r"-(eastern|western)-conference-semifinals", s):
            round_, seq = "Conference Semifinals", 2
        elif "conference-finals" in s:
            round_, seq = "Conference Finals", 3
        elif "first-round" in s:
            round_, seq = "First Round", 1
        elif re.search(r"nba-finals", s):
            round_, seq = "Finals", 4
        elif "play-in" in s:
            round_, seq = "Play-In", 0
        if "eastern" in s:
            conf = "Eastern"
        elif "western" in s:
            conf = "Western"
        m = re.search(r"-([a-z0-9]+)-vs-([a-z0-9]+)$", s)
        ta, tb = (m.group(1), m.group(2)) if m else (None, None)
        rows.append({
            "series_slug": s, "season": SEASON, "round": round_, "round_seq": seq,
            "conference": conf, "team_a_abbr": ta, "team_b_abbr": tb,
            "winner_abbr": None, "games_played": None, "fetched_at": _now_utc(),
        })
    return rows


# ───────────────────────────────────────────────────────── load
def _insert(cur, table, cols, rows):
    if not rows:
        return 0
    placeholders = ",".join(["%s"] * len(cols))
    sql = f"INSERT INTO ZK_NBA_V2.FLAT.{table} ({','.join(cols)}) VALUES ({placeholders})"
    cur.executemany(sql, [tuple(r[c] for c in cols) for r in rows])
    return len(rows)


GAME_COLS = ["game_id", "game_date", "season", "season_type", "round", "series_slug",
             "game_in_series", "home_team_abbr", "away_team_abbr", "home_pts", "away_pts",
             "home_wl", "arena_name", "arena_city", "arena_state",
             "home_fgm", "home_fga", "home_fg_pct", "home_fg3m", "home_fg3a", "home_fg3_pct",
             "home_ftm", "home_fta", "home_ft_pct", "home_oreb", "home_dreb", "home_reb",
             "home_ast", "home_stl", "home_blk", "home_tov", "home_pf", "home_plus_minus",
             "away_fgm", "away_fga", "away_fg_pct", "away_fg3m", "away_fg3a", "away_fg3_pct",
             "away_ftm", "away_fta", "away_ft_pct", "away_oreb", "away_dreb", "away_reb",
             "away_ast", "away_stl", "away_blk", "away_tov", "away_pf", "away_plus_minus",
             "fetched_at"]
BASIC_COLS = ["game_id", "player_id", "player_name", "team_abbr", "is_home", "is_starter",
              "is_win", "season", "season_type", "minutes_played", "pts", "ast", "reb",
              "oreb", "dreb", "stl", "blk", "tov", "pf", "fgm", "fga", "fg_pct", "fg3m",
              "fg3a", "fg3_pct", "ftm", "fta", "ft_pct", "plus_minus", "game_score", "fetched_at"]
ADV_COLS = ["game_id", "player_id", "ts_pct", "efg_pct", "fg3a_rate", "fta_rate", "orb_pct",
            "drb_pct", "trb_pct", "ast_pct", "stl_pct", "blk_pct", "tov_pct", "usg_pct",
            "ortg", "drtg", "bpm", "fetched_at"]
LINE_COLS = ["game_id", "game_date", "home_team_abbr", "home_q1", "home_q2", "home_q3",
             "home_q4", "home_ot1", "home_ot2", "home_ot3", "home_ot4", "home_pts",
             "away_team_abbr", "away_q1", "away_q2", "away_q3", "away_q4", "away_ot1",
             "away_ot2", "away_ot3", "away_ot4", "away_pts", "fetched_at"]
SERIES_COLS = ["series_slug", "season", "round", "round_seq", "conference", "team_a_abbr",
               "team_b_abbr", "winner_abbr", "games_played", "fetched_at"]


def remap_game_row(raw, season_type, round_, series_slug, game_in_series, arena):
    """flatten_game_row output (V1 shape) -> V2 games row."""
    keep = {k: raw.get(k) for k in GAME_COLS if k in raw}
    keep["season"] = SEASON
    keep["season_type"] = season_type
    keep["round"] = round_
    keep["series_slug"] = series_slug
    keep["game_in_series"] = game_in_series
    keep["arena_name"], keep["arena_city"], keep["arena_state"] = arena
    for c in GAME_COLS:
        keep.setdefault(c, None)
    return keep


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0, help="process only first N games")
    args = ap.parse_args()

    log.info("Enumerating %s %s games…", TEAM, SEASON)
    den_html = fetch(f"{BASE_URL}/teams/{TEAM}/{SEASON}_games.html")
    slugs = extract_game_slugs_from_html(den_html)
    if args.limit:
        slugs = slugs[: args.limit]
    log.info("%d games to process", len(slugs))

    series = fetch_playoff_series()
    den_series = {r["round"]: r["series_slug"] for r in series if r["team_a_abbr"] == TEAM_NICK or r["team_b_abbr"] == TEAM_NICK}
    log.info("playoff_series rows=%d; DEN series=%s", len(series), den_series)

    games, basics, advs, lines, quarantine = [], [], [], [], []

    for i, slug in enumerate(slugs, 1):
        try:
            html = fetch(f"{BASE_URL}/boxscores/{slug}.html")
            visible, hidden = parse_tables_with_comments(html)
            home, away = _find_team_abbrs_from_tables(slug, visible)
            hb = visible.get(f"box-{home}-game-basic")
            ab = visible.get(f"box-{away}-game-basic")
            # GUARD: structural drift — fail loud, do not write empty rows.
            if hb is None or ab is None or hidden.get("line_score") is None:
                quarantine.append((slug, "missing required table (basic/line_score)"))
                log.warning("[%d/%d] %s QUARANTINED: missing required table", i, len(slugs), slug)
                continue

            soup = BeautifulSoup(html, "html5lib")
            h1 = (soup.find("h1").get_text(" ", strip=True) if soup.find("h1") else "")
            season_type, round_, gis = parse_round_from_h1(h1)
            series_slug = den_series.get(round_) if round_ else None
            arena = parse_arena(soup)
            anchors = _extract_player_anchors(html)

            raw_game = flatten_game_row(slug, home, away, hb, ab, hidden.get("line_score"))
            if raw_game is None:
                quarantine.append((slug, "no team totals"))
                continue
            game_row = remap_game_row(raw_game, season_type, round_, series_slug, gis, arena)

            home_win = game_row["home_pts"] > game_row["away_pts"]
            box = (flatten_basic_v2(slug, home, hb, True, home_win, season_type, anchors)
                   + flatten_basic_v2(slug, away, ab, False, not home_win, season_type, anchors))

            violations = guard(game_row, box)
            if violations:
                quarantine.append((slug, "; ".join(violations[:5])))
                log.warning("[%d/%d] %s QUARANTINED: %s", i, len(slugs), slug, violations[:3])
                continue

            adv = (flatten_advanced_v2(slug, visible.get(f"box-{home}-game-advanced"), anchors)
                   + flatten_advanced_v2(slug, visible.get(f"box-{away}-game-advanced"), anchors))
            line = flatten_line_score(slug, hidden.get("line_score"))
            if line:
                line.pop("source", None)

            games.append(game_row)
            basics.extend(box)
            advs.extend(adv)
            if line:
                lines.append(line)
            tag = f"{round_} G{gis}" if round_ else "reg"
            log.info("[%d/%d] %s OK (%s, %d players)", i, len(slugs), slug, tag, len(box))
        except Exception as exc:  # noqa: BLE001 — fail loud per game, keep going
            quarantine.append((slug, f"error: {exc!r}"))
            log.error("[%d/%d] %s ERROR: %r", i, len(slugs), slug, exc)

    # ── load ────────────────────────────────────────────────────────────────
    log.info("Loading: %d games, %d box, %d adv, %d line, %d series; %d quarantined",
             len(games), len(basics), len(advs), len(lines), len(series), len(quarantine))
    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute("CREATE TABLE IF NOT EXISTS ZK_NBA_V2.FLAT.quarantine "
                    "(game_id STRING, reason STRING, fetched_at TIMESTAMP_NTZ)")
        for t in ("games", "player_box_basic", "player_box_advanced", "line_scores",
                  "playoff_series", "quarantine"):
            cur.execute(f"DELETE FROM ZK_NBA_V2.FLAT.{t}")  # idempotent re-run of the slice
        _insert(cur, "playoff_series", SERIES_COLS, series)
        _insert(cur, "games", GAME_COLS, games)
        _insert(cur, "player_box_basic", BASIC_COLS, basics)
        _insert(cur, "player_box_advanced", ADV_COLS, advs)
        _insert(cur, "line_scores", LINE_COLS, lines)
        if quarantine:
            now = _now_utc()
            cur.executemany("INSERT INTO ZK_NBA_V2.FLAT.quarantine VALUES (%s,%s,%s)",
                            [(g, r, now) for g, r in quarantine])
        cur.close()
        conn.commit()
    finally:
        conn.close()

    print(f"\nDONE. games={len(games)} box_rows={len(basics)} quarantined={len(quarantine)}")
    if quarantine:
        print("QUARANTINED (not loaded):")
        for g, r in quarantine:
            print(f"  {g}: {r}")


if __name__ == "__main__":
    sys.exit(main())
