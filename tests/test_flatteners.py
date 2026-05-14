"""Unit tests for flatteners.

Pure Python — no Snowflake connection required. Tests verify that the
transform logic handles BR's quirky HTML output correctly.

Run:
    pytest tests/test_flatteners.py -v
"""

from __future__ import annotations

import math
from datetime import date

import pandas as pd
import pytest

from nba_ingest.flatteners.boxscore import (
    flatten_game_row,
    flatten_line_score,
    flatten_player_box_advanced,
    flatten_player_box_basic,
    _drop_totals_row,
    _flatten_columns,
    _parse_minutes,
    _season_from_slug,
)
from nba_ingest.flatteners.draft import flatten_draft_career_stats


# ──────────────────────────────────────────────────────────────────────────────
# Helpers to build test fixtures
# ──────────────────────────────────────────────────────────────────────────────


def _make_basic_df(rows: list[dict]) -> pd.DataFrame:
    """Build a basic box score DataFrame from a list of dicts."""
    return pd.DataFrame(rows)


def _sample_basic_df() -> pd.DataFrame:
    """A realistic basic box score DataFrame (3 players + totals row)."""
    return pd.DataFrame({
        "Player": ["Nikola Jokic", "Jamal Murray", "Team Totals"],
        "MP":     ["32:15",        "38:42",        "240:00"],
        "FG":     [11,             8,               28],
        "FGA":    [18,             16,              56],
        "FG%":    [0.611,          0.500,           0.500],
        "3P":     [1,              3,               7],
        "3PA":    [3,              8,               22],
        "3P%":    [0.333,          0.375,           0.318],
        "FT":     [5,              3,               12],
        "FTA":    [5,              4,               14],
        "FT%":    [1.000,          0.750,           0.857],
        "ORB":    [6,              1,               10],
        "DRB":    [10,             4,               25],
        "TRB":    [16,             5,               35],
        "AST":    [12,             7,               20],
        "STL":    [3,              2,               6],
        "BLK":    [2,              0,               3],
        "TOV":    [3,              2,               8],
        "PF":     [1,              3,               12],
        "PTS":    [28,             19,              75],
        "+/-":    [5,              -2,              0],
    })


# ──────────────────────────────────────────────────────────────────────────────
# Tests: _parse_minutes
# ──────────────────────────────────────────────────────────────────────────────


def test_parse_minutes_standard():
    assert abs(_parse_minutes("32:15") - 32.25) < 0.01


def test_parse_minutes_zero():
    assert _parse_minutes("0:00") == 0.0


def test_parse_minutes_dnp():
    assert _parse_minutes("Did Not Play") is None


def test_parse_minutes_nan():
    assert _parse_minutes(float("nan")) is None


def test_parse_minutes_none():
    assert _parse_minutes(None) is None


# ──────────────────────────────────────────────────────────────────────────────
# Tests: _flatten_columns
# ──────────────────────────────────────────────────────────────────────────────


def test_flatten_columns_multiindex():
    """Multi-level column headers are flattened to short names (last tuple element).

    The original buggy behaviour joined ALL levels ('Basic Box Score Stats_MP')
    which broke every stat lookup since the code uses short names ('MP').
    Correct: take only the last element.
    """
    tuples = [("Basic Box Score Stats", "MP"), ("Basic Box Score Stats", "PTS")]
    multi = pd.MultiIndex.from_tuples(tuples)
    df = pd.DataFrame([[1, 2]], columns=multi)
    flat = _flatten_columns(df)
    assert "MP" in flat.columns, "Expected short name 'MP', not full path"
    assert "PTS" in flat.columns, "Expected short name 'PTS', not full path"
    assert "Basic Box Score Stats_MP" not in flat.columns, "Old broken prefix must be gone"


def test_flatten_columns_single_level():
    """Single-level columns pass through unchanged."""
    df = pd.DataFrame({"MP": [1], "PTS": [2]})
    flat = _flatten_columns(df)
    assert list(flat.columns) == ["MP", "PTS"]


# ──────────────────────────────────────────────────────────────────────────────
# Tests: _drop_totals_row
# ──────────────────────────────────────────────────────────────────────────────


def test_drop_totals_row_removes_totals():
    """Team Totals row is excluded from output."""
    df = _sample_basic_df()
    clean = _drop_totals_row(df)
    assert "Team Totals" not in clean["Player"].values
    assert len(clean) == 2  # Only Jokic and Murray


def test_drop_totals_row_keeps_players():
    """Real player rows are preserved after totals removal."""
    df = _sample_basic_df()
    clean = _drop_totals_row(df)
    assert "Nikola Jokic" in clean["Player"].values
    assert "Jamal Murray" in clean["Player"].values


def test_drop_totals_row_removes_starters_header():
    """'Starters' header rows (BR inserts them as section labels) are dropped."""
    df = pd.DataFrame({
        "Player": ["Starters", "Nikola Jokic", "Reserves", "Bruce Brown", "Team Totals"],
        "MP": ["", "32:15", "", "24:00", "240:00"],
        "PTS": [None, 28, None, 8, 75],
    })
    clean = _drop_totals_row(df)
    assert "Starters" not in clean["Player"].values
    assert "Reserves" not in clean["Player"].values
    assert "Team Totals" not in clean["Player"].values
    assert "Nikola Jokic" in clean["Player"].values


# ──────────────────────────────────────────────────────────────────────────────
# Tests: flatten_player_box_basic
# ──────────────────────────────────────────────────────────────────────────────


def test_flatten_player_box_basic_count():
    """Returns one row per player (excluding totals)."""
    df = _sample_basic_df()
    rows = flatten_player_box_basic("20230612ODAL", "DEN", df, is_home=True)
    assert len(rows) == 2


def test_flatten_player_box_basic_schema():
    """Each row has the required schema keys."""
    df = _sample_basic_df()
    rows = flatten_player_box_basic("20230612ODAL", "DEN", df, is_home=True)
    required_keys = {"game_id", "player_name", "team_abbr", "is_home", "pts", "ast", "reb", "source"}
    for row in rows:
        assert required_keys.issubset(row.keys()), f"Missing keys: {required_keys - row.keys()}"


def test_flatten_player_box_basic_source_is_br_scrape():
    """source field is 'br_scrape' for BR-scraped data."""
    df = _sample_basic_df()
    rows = flatten_player_box_basic("20230612ODAL", "DEN", df, is_home=True)
    assert all(r["source"] == "br_scrape" for r in rows)


def test_flatten_player_box_basic_nan_minutes_becomes_zero():
    """A player with NaN minutes_played maps to 0.0, not None."""
    df = pd.DataFrame({
        "Player": ["Inactive Guy"],
        "MP":     [float("nan")],
        "PTS":    [0],
        "AST":    [0],
        "TRB":    [0],
        "ORB":    [0], "DRB": [0], "STL": [0], "BLK": [0], "TOV": [0], "PF": [0],
        "FG":     [0], "FGA": [0], "FG%": [float("nan")],
        "3P":     [0], "3PA": [0], "3P%": [float("nan")],
        "FT":     [0], "FTA": [0], "FT%": [float("nan")],
        "+/-":    [0],
    })
    rows = flatten_player_box_basic("20230612ODAL", "DEN", df, is_home=True)
    assert len(rows) == 1
    assert rows[0]["minutes_played"] == 0.0


def test_flatten_player_box_basic_game_id_from_slug():
    """game_id is set to the game slug."""
    df = _sample_basic_df()
    slug = "20230612ODAL"
    rows = flatten_player_box_basic(slug, "DEN", df, is_home=True)
    assert all(r["game_id"] == slug for r in rows)


def test_flatten_player_box_basic_is_home_flag():
    """is_home flag is correctly propagated."""
    df = _sample_basic_df()
    home_rows = flatten_player_box_basic("20230612ODAL", "DEN", df, is_home=True)
    away_rows = flatten_player_box_basic("20230612ODAL", "MIA", df, is_home=False)
    assert all(r["is_home"] is True for r in home_rows)
    assert all(r["is_home"] is False for r in away_rows)


# ──────────────────────────────────────────────────────────────────────────────
# Tests: flatten_line_score
# ──────────────────────────────────────────────────────────────────────────────


def test_flatten_line_score_returns_both_teams():
    """flatten_line_score returns a single dict with both home and away team data."""
    df = pd.DataFrame({
        0: ["MIA", "DEN"],  # Away first, then home (BR convention)
        "1":  [22, 25],
        "2":  [25, 18],
        "3":  [19, 22],
        "4":  [23, 29],
        "T":  [89, 94],
    })
    result = flatten_line_score("20230612ODAL", df)
    assert result is not None
    assert result["home_team_abbr"] == "DEN"
    assert result["away_team_abbr"] == "MIA"
    assert result["home_pts"] == 94
    assert result["away_pts"] == 89


def test_flatten_line_score_none_on_missing_df():
    """Returns None when the DataFrame is None."""
    result = flatten_line_score("20230612ODAL", None)
    assert result is None


def test_flatten_line_score_none_on_empty_df():
    """Returns None when the DataFrame is empty."""
    result = flatten_line_score("20230612ODAL", pd.DataFrame())
    assert result is None


def test_flatten_line_score_game_id_from_slug():
    """game_id in the result matches the slug argument."""
    df = pd.DataFrame({
        0: ["MIA", "DEN"],
        "1": [22, 25], "2": [25, 18], "3": [19, 22], "4": [23, 29], "T": [89, 94],
    })
    result = flatten_line_score("20230612ODAL", df)
    assert result["game_id"] == "20230612ODAL"


# ──────────────────────────────────────────────────────────────────────────────
# Tests: flatten_draft_career_stats
# ──────────────────────────────────────────────────────────────────────────────


def test_flatten_draft_career_stats_basic():
    """Returns one row per pick, skipping header rows."""
    df = pd.DataFrame({
        "Pk": ["Pk", "1", "2", "Pk"],   # Header rows interspersed
        "Player": ["Player", "Victor Wembanyama", "Scoot Henderson", "Player"],
        "Tm": ["Tm", "SAS", "POR", "Tm"],
        "College": ["College", "", "Memphis", "College"],
        "G": [None, 72, 68, None],
        "PTS": [None, 21.4, 16.3, None],
        "TRB": [None, 10.6, 4.4, None],
        "AST": [None, 3.9, 5.8, None],
        "FG%": [None, 0.462, 0.445, None],
        "3P%": [None, 0.324, 0.337, None],
        "FT%": [None, 0.787, 0.783, None],
        "WS": [None, 6.3, 2.1, None],
        "WS/48": [None, 0.089, 0.034, None],
        "BPM": [None, 4.2, -1.1, None],
        "VORP": [None, 3.2, 0.5, None],
    })
    rows = flatten_draft_career_stats(2023, df)
    # Should have exactly 2 rows (Wembanyama + Henderson); header rows skipped
    assert len(rows) == 2
    assert rows[0]["player_name"] == "Victor Wembanyama"
    assert rows[0]["season"] == 2023
    assert rows[0]["overall_pick"] == 1
    assert rows[1]["overall_pick"] == 2


def _team_totals_df(team_label: str, **stats) -> pd.DataFrame:
    """Build a basic-box DataFrame containing one player row + Team Totals row."""
    row_player = {"Player": "Some Player", "MP": "32:00", "PTS": 0, "AST": 0, "TRB": 0,
                  "ORB": 0, "DRB": 0, "STL": 0, "BLK": 0, "TOV": 0, "PF": 0,
                  "FG": 0, "FGA": 0, "FG%": 0.0, "3P": 0, "3PA": 0, "3P%": 0.0,
                  "FT": 0, "FTA": 0, "FT%": 0.0, "+/-": 0}
    row_totals = {"Player": "Team Totals", "MP": "240:00", **stats}
    return pd.DataFrame([row_player, row_totals])


# ──────────────────────────────────────────────────────────────────────────────
# Tests: _season_from_slug
# ──────────────────────────────────────────────────────────────────────────────


def test_season_from_slug_fall_game():
    """Nov 15, 2023 is part of the 2023-24 season (end year = 2024)."""
    assert _season_from_slug("202311150LAL") == 2024


def test_season_from_slug_spring_game():
    """Apr 9, 2024 is part of the 2023-24 season (end year = 2024)."""
    assert _season_from_slug("202404090MEM") == 2024


def test_season_from_slug_june_finals():
    """June games are still part of the season ending that calendar year."""
    assert _season_from_slug("202306120DEN") == 2023


# ──────────────────────────────────────────────────────────────────────────────
# Tests: flatten_game_row (Slice A core)
# ──────────────────────────────────────────────────────────────────────────────


def test_flatten_game_row_basic_identity():
    """Returns one row with game_id, date, season, team abbrs, scores."""
    home_df = _team_totals_df("MEM", PTS=87, FG=36, FGA=104, **{"FG%": 0.346},
                              **{"3P": 6, "3PA": 30, "3P%": 0.200},
                              FT=9, FTA=11, **{"FT%": 0.818},
                              ORB=17, DRB=32, TRB=49, AST=21, STL=10, BLK=5, TOV=8, PF=13)
    away_df = _team_totals_df("SAS", PTS=102, FG=42, FGA=87, **{"FG%": 0.483},
                              **{"3P": 10, "3PA": 40, "3P%": 0.250},
                              FT=8, FTA=8, **{"FT%": 1.000},
                              ORB=10, DRB=41, TRB=51, AST=30, STL=5, BLK=11, TOV=17, PF=12)
    row = flatten_game_row(
        game_slug="202404090MEM",
        home_team="MEM",
        away_team="SAS",
        home_basic_df=home_df,
        away_basic_df=away_df,
    )
    assert row is not None
    assert row["game_id"] == "202404090MEM"
    assert row["game_date"] == "2024-04-09"
    assert row["season"] == 2024
    assert row["home_team_abbr"] == "MEM"
    assert row["away_team_abbr"] == "SAS"
    assert row["home_pts"] == 87
    assert row["away_pts"] == 102


def test_flatten_game_row_home_wl_loss():
    """home_wl is 'L' when home_pts < away_pts."""
    home_df = _team_totals_df("MEM", PTS=87, FG=36, FGA=104)
    away_df = _team_totals_df("SAS", PTS=102, FG=42, FGA=87)
    row = flatten_game_row("202404090MEM", "MEM", "SAS", home_df, away_df)
    assert row["home_wl"] == "L"


def test_flatten_game_row_home_wl_win():
    """home_wl is 'W' when home_pts > away_pts."""
    home_df = _team_totals_df("MEM", PTS=110, FG=40, FGA=80)
    away_df = _team_totals_df("SAS", PTS=95, FG=35, FGA=85)
    row = flatten_game_row("202404090MEM", "MEM", "SAS", home_df, away_df)
    assert row["home_wl"] == "W"


def test_flatten_game_row_source_and_team_stats():
    """source='br_scrape' and team stat columns populated from totals row."""
    home_df = _team_totals_df("MEM", PTS=87, FG=36, FGA=104, **{"FG%": 0.346},
                              **{"3P": 6, "3PA": 30}, FT=9, FTA=11,
                              ORB=17, DRB=32, TRB=49, AST=21, STL=10, BLK=5, TOV=8, PF=13)
    away_df = _team_totals_df("SAS", PTS=102, FG=42, FGA=87,
                              **{"3P": 10, "3PA": 40}, AST=30, BLK=11)
    row = flatten_game_row("202404090MEM", "MEM", "SAS", home_df, away_df)
    assert row["source"] == "br_scrape"
    assert row["home_fgm"] == 36
    assert row["home_fga"] == 104
    assert row["home_ast"] == 21
    assert row["away_fg3a"] == 40
    assert row["away_blk"] == 11


def test_flatten_game_row_returns_none_when_totals_missing():
    """No Team Totals row in the DF means we can't form a games row — return None."""
    # Build a DF with only a player row, no Team Totals
    no_totals_df = pd.DataFrame([{"Player": "Player A", "PTS": 28, "FG": 10, "FGA": 20}])
    home_df_ok = _team_totals_df("MEM", PTS=87, FG=36, FGA=104)
    result = flatten_game_row("202404090MEM", "MEM", "SAS", no_totals_df, home_df_ok)
    assert result is None


def test_flatten_draft_career_stats_nulls_for_no_stats():
    """Players with no career stats yet (0 games) return None for stat fields."""
    df = pd.DataFrame({
        "Pk": ["3"],
        "Player": ["Brandon Miller"],
        "Tm": ["CHA"],
        "College": ["Alabama"],
        "G": [None],
        "PTS": [None],
        "TRB": [None],
        "AST": [None],
        "FG%": [None], "3P%": [None], "FT%": [None],
        "WS": [None], "WS/48": [None], "BPM": [None], "VORP": [None],
    })
    rows = flatten_draft_career_stats(2023, df)
    assert len(rows) == 1
    assert rows[0]["career_games"] is None
    assert rows[0]["career_pts_per_game"] is None
