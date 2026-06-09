"""Reusable V2 slice logic — flatten, guard, round/series tagging, load.

Promoted from the Phase 1 dev orchestrator (favor-to-future-us per the Phase 1
reflection) so Phase 2 (all teams) and Phase 3 (history) share one implementation.
Single source: every identifier is BR-native (player slug, team abbr). No
NBA-Stats ids, no `source` column, no game_id impersonation.
"""

from __future__ import annotations

import logging
import re
import time

import requests
from bs4 import BeautifulSoup

from nba_ingest.br_client import (
    BASE_URL,
    extract_game_slugs_from_html,
    fetch,
    parse_tables_with_comments,
)
from nba_ingest.fetchers.boxscore import (
    _extract_player_anchors,
    _find_team_abbrs_from_tables,
    _parse_meta,
)
from nba_ingest.fetchers.schedule import SEASON_MONTHS

log = logging.getLogger(__name__)


def _fetch_retry(url: str, tries: int = 3) -> str:
    """fetch() with retry on transient connection errors (Phase 2 surfaced one
    ConnectionReset over ~1300 games). Distinct from a permanent 404/parse fail."""
    for i in range(tries):
        try:
            return fetch(url)
        except requests.exceptions.ConnectionError:
            if i == tries - 1:
                raise
            time.sleep(8)
    raise RuntimeError("unreachable")


def enumerate_season_by_schedule(season: int) -> list[str]:
    """All game slugs for a season via the league monthly schedule pages.

    Works for any era (defunct franchises included) and is ~9 fetches/season —
    unlike team-page enumeration, which needs current abbrs and misses the NBA
    Cup final (Phase 2 parity delta). Skips months whose page doesn't exist.
    """
    seen, out = set(), []
    for month in SEASON_MONTHS:
        try:
            html = _fetch_retry(f"{BASE_URL}/leagues/NBA_{season}_games-{month}.html")
        except requests.HTTPError:
            continue  # off-season / nonexistent month page for this era
        for slug in extract_game_slugs_from_html(html):
            if slug not in seen:
                seen.add(slug)
                out.append(slug)
    return out
from nba_ingest.flatteners.boxscore import (
    _drop_totals_row,
    _flatten_columns,
    _now_utc,
    _parse_minutes,
    _safe_float,
    _safe_int,
    flatten_game_row,
    flatten_line_score,
)

# BR series-slug nicknames per team abbr (for matching a playoff game to its
# series). Accurate for all 30; only the season's playoff teams actually matter.
TEAM_NICKNAMES = {
    "ATL": "hawks", "BOS": "celtics", "BRK": "nets", "CHO": "hornets",
    "CHI": "bulls", "CLE": "cavaliers", "DAL": "mavericks", "DEN": "nuggets",
    "DET": "pistons", "GSW": "warriors", "HOU": "rockets", "IND": "pacers",
    "LAC": "clippers", "LAL": "lakers", "MEM": "grizzlies", "MIA": "heat",
    "MIL": "bucks", "MIN": "timberwolves", "NOP": "pelicans", "NYK": "knicks",
    "OKC": "thunder", "ORL": "magic", "PHI": "76ers", "PHO": "suns",
    "POR": "trail-blazers", "SAC": "kings", "SAS": "spurs", "TOR": "raptors",
    "UTA": "jazz", "WAS": "wizards",
}

CANONICAL_ROUNDS = [  # most-specific first ("Finals" is a substring of "...Finals")
    ("Conference Semifinals", "Conference Semifinals", 2),
    ("Conference Finals", "Conference Finals", 3),
    ("Division Semifinals", "Division Semifinals", 2),   # pre-1971 era playoff naming
    ("Division Finals", "Division Finals", 3),           # (1970s used divisions, not conferences)
    ("First Round", "First Round", 1),
    ("Play-In", "Play-In", 0),
    ("Finals", "Finals", 4),
]


# ───────────────────────────────────────────────────────────── parsing
def parse_round_from_h1(h1: str) -> tuple[str, str | None, int | None]:
    """(season_type, round, game_in_series) from a boxscore <h1>."""
    for needle, canon, _seq in CANONICAL_ROUNDS:
        if needle.lower() in h1.lower():
            gm = re.search(r"Game (\d+)", h1)
            season_type = "Play-In" if canon == "Play-In" else "Playoffs"
            return season_type, canon, (int(gm.group(1)) if gm else None)
    return "Regular Season", None, None


def parse_arena(soup: BeautifulSoup) -> tuple[str | None, str | None, str | None]:
    meta = soup.find("div", class_="scorebox_meta")
    if not meta:
        return None, None, None
    for seg in (s.strip() for s in meta.get_text("|").split("|") if s.strip()):
        if ("AM" in seg or "PM" in seg) and re.search(r"\d{4}", seg):
            continue  # date/time segment
        parts = [p.strip() for p in seg.split(",")]
        if len(parts) >= 2:
            return parts[0], parts[1], (parts[2] if len(parts) >= 3 else None)
    return None, None, None


def _starters(basic_df) -> set[str]:
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


# ───────────────────────────────────────────────────────────── flatten
def flatten_basic(slug, team_abbr, df, is_home, is_win, season, season_type, anchors):
    if df is None or df.empty:
        return []
    starters = _starters(df)
    d = _drop_totals_row(_flatten_columns(df.copy()))
    rows = []
    for _, r in d.iterrows():
        name = str(r.get("Player", r.iloc[0])).strip()
        # Parse each stat directly. _safe_int returns None for genuine "Did Not
        # Play" cells AND for not-tracked columns (e.g. STL pre-1973-74). Do NOT
        # infer DNP from missing minutes: pre-~1985 box scores omit MP for players
        # who clearly played (a 39-pt NaN-MP line is not a DNP). Zeroing on
        # missing MP was an era bug that 1972-73 exposed.
        rows.append({
            "game_id": slug, "player_id": anchors.get(name) or name, "player_name": name,
            "team_abbr": team_abbr, "is_home": is_home, "is_starter": name in starters,
            "is_win": is_win, "season": season, "season_type": season_type,
            "minutes_played": _parse_minutes(r.get("MP")),
            "pts": _safe_int(r.get("PTS")), "ast": _safe_int(r.get("AST")), "reb": _safe_int(r.get("TRB")),
            "oreb": _safe_int(r.get("ORB")), "dreb": _safe_int(r.get("DRB")), "stl": _safe_int(r.get("STL")),
            "blk": _safe_int(r.get("BLK")), "tov": _safe_int(r.get("TOV")), "pf": _safe_int(r.get("PF")),
            "fgm": _safe_int(r.get("FG")), "fga": _safe_int(r.get("FGA")), "fg_pct": _safe_float(r.get("FG%")),
            "fg3m": _safe_int(r.get("3P")), "fg3a": _safe_int(r.get("3PA")), "fg3_pct": _safe_float(r.get("3P%")),
            "ftm": _safe_int(r.get("FT")), "fta": _safe_int(r.get("FTA")), "ft_pct": _safe_float(r.get("FT%")),
            "plus_minus": _safe_float(r.get("+/-")), "game_score": _safe_float(r.get("GmSc")),
            "fetched_at": _now_utc(),
        })
    return rows


def flatten_advanced(slug, df, anchors):
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


def flatten_officials(slug, meta):
    rows = []
    for o in meta.get("officials_with_slugs", []):
        rows.append({"game_id": slug, "official_id": o.get("br_slug") or o.get("name"),
                     "official_name": o.get("name"), "fetched_at": _now_utc()})
    return rows


def flatten_inactives(slug, meta):
    rows = []
    for team_abbr, players in meta.get("inactives_by_team", {}).items():
        for p in players:
            rows.append({"game_id": slug, "player_id": p.get("br_slug") or p.get("name"),
                         "player_name": p.get("name"), "team_abbr": team_abbr,
                         "fetched_at": _now_utc()})
    return rows


# ───────────────────────────────────────────────────────────── guard
def guard(game_row, basic_rows) -> list[str]:
    """Basketball domain-range checks. Empty list = clean."""
    v = []
    hp, ap = game_row["home_pts"], game_row["away_pts"]
    if hp is None or ap is None:
        v.append("missing team points")
    elif hp == ap:
        v.append(f"tie game ({hp}={ap})")
    for r in basic_rows:
        for made, att in (("fgm", "fga"), ("fg3m", "fg3a"), ("ftm", "fta")):
            if r[made] is not None and r[att] is not None and r[made] > r[att]:
                v.append(f"{r['player_name']}: {made}>{att}")
        if r["pts"] is not None and not (0 <= r["pts"] <= 105):
            v.append(f"{r['player_name']}: pts {r['pts']}")
        if r["fg_pct"] is not None and not (0 <= r["fg_pct"] <= 1):
            v.append(f"{r['player_name']}: fg_pct {r['fg_pct']}")
    for abbr, total in ((game_row["home_team_abbr"], hp), (game_row["away_team_abbr"], ap)):
        s = sum(r["pts"] or 0 for r in basic_rows if r["team_abbr"] == abbr)
        if total is not None and s != total:
            v.append(f"{abbr}: player-pts {s} != team {total}")
    return v


# ───────────────────────────────────────────────────────────── bracket
def fetch_playoff_series(season: int) -> list[dict]:
    html = fetch(f"{BASE_URL}/playoffs/NBA_{season}.html")
    slugs = sorted(set(re.findall(rf"/playoffs/({season}-nba-[a-z0-9-]+)\.html", html)))
    rows = []
    for s in slugs:
        round_, seq = None, None
        if "conference-semifinals" in s:
            round_, seq = "Conference Semifinals", 2
        elif "conference-finals" in s:
            round_, seq = "Conference Finals", 3
        elif "first-round" in s:
            round_, seq = "First Round", 1
        elif re.search(r"nba-finals", s):
            round_, seq = "Finals", 4
        elif "play-in" in s:
            round_, seq = "Play-In", 0
        conf = "Eastern" if "eastern" in s else ("Western" if "western" in s else None)
        m = re.search(r"-([a-z0-9]+)-vs-([a-z0-9-]+)$", s)
        ta, tb = (m.group(1), m.group(2)) if m else (None, None)
        rows.append({"series_slug": s, "season": season, "round": round_, "round_seq": seq,
                     "conference": conf, "team_a_abbr": ta, "team_b_abbr": tb,
                     "winner_abbr": None, "games_played": None, "fetched_at": _now_utc()})
    return rows


def match_series(round_, home_abbr, away_abbr, series_rows):
    """Find the series_slug for a playoff game by round + both teams' nicknames."""
    if not round_:
        return None
    hn, an = TEAM_NICKNAMES.get(home_abbr), TEAM_NICKNAMES.get(away_abbr)
    for s in series_rows:
        if s["round"] == round_ and hn and an and hn in s["series_slug"] and an in s["series_slug"]:
            return s["series_slug"]
    return None


# ───────────────────────────────────────────────────────────── transform one game
def build_game(slug, season, series_rows):
    """Fetch + flatten one game into a dict of row-lists, or ('quarantine', reason)."""
    html = _fetch_retry(f"{BASE_URL}/boxscores/{slug}.html")
    visible, hidden = parse_tables_with_comments(html)
    home, away = _find_team_abbrs_from_tables(slug, visible)
    hb, ab = visible.get(f"box-{home}-game-basic"), visible.get(f"box-{away}-game-basic")
    if hb is None or ab is None or hidden.get("line_score") is None:
        return ("quarantine", "missing required table (basic/line_score)")

    soup = BeautifulSoup(html, "html5lib")
    h1 = soup.find("h1").get_text(" ", strip=True) if soup.find("h1") else ""
    season_type, round_, gis = parse_round_from_h1(h1)
    series_slug = match_series(round_, home, away, series_rows)
    arena = parse_arena(soup)
    anchors = _extract_player_anchors(html)
    meta = _parse_meta(html)

    raw = flatten_game_row(slug, home, away, hb, ab, hidden.get("line_score"))
    if raw is None:
        return ("quarantine", "no team totals")
    game_row = {k: raw.get(k) for k in GAME_COLS}
    game_row.update(season=season, season_type=season_type, round=round_,
                    series_slug=series_slug, game_in_series=gis,
                    arena_name=arena[0], arena_city=arena[1], arena_state=arena[2])

    home_win = game_row["home_pts"] > game_row["away_pts"]
    basics = (flatten_basic(slug, home, hb, True, home_win, season, season_type, anchors)
              + flatten_basic(slug, away, ab, False, not home_win, season, season_type, anchors))
    violations = guard(game_row, basics)
    if violations:
        return ("quarantine", "; ".join(violations[:5]))

    advs = (flatten_advanced(slug, visible.get(f"box-{home}-game-advanced"), anchors)
            + flatten_advanced(slug, visible.get(f"box-{away}-game-advanced"), anchors))
    line = flatten_line_score(slug, hidden.get("line_score"))
    if line:
        line.pop("source", None)
    return {"games": [game_row], "player_box_basic": basics, "player_box_advanced": advs,
            "line_scores": [line] if line else [], "game_officials": flatten_officials(slug, meta),
            "game_inactives": flatten_inactives(slug, meta)}


# ───────────────────────────────────────────────────────────── load
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
OFFICIALS_COLS = ["game_id", "official_id", "official_name", "fetched_at"]
INACTIVES_COLS = ["game_id", "player_id", "player_name", "team_abbr", "fetched_at"]
COLS = {"games": GAME_COLS, "player_box_basic": BASIC_COLS, "player_box_advanced": ADV_COLS,
        "line_scores": LINE_COLS, "game_officials": OFFICIALS_COLS, "game_inactives": INACTIVES_COLS}


def insert(cur, table, rows, cols=None):
    if not rows:
        return 0
    cols = cols or COLS[table]
    ph = ",".join(["%s"] * len(cols))
    cur.executemany(f"INSERT INTO ZK_NBA_V2.FLAT.{table} ({','.join(cols)}) VALUES ({ph})",
                    [tuple(r.get(c) for c in cols) for r in rows])
    return len(rows)
