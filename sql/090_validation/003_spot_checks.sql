-- ============================================================
-- Slice 1 validation: spot checks against known real-world facts.
-- Each check has an expected value verified against JB_HISTORIC_NBA source
-- AND against Basketball-Reference as a second source of truth.
--
-- Philosophy: row counts confirm shape; spot checks confirm correctness.
-- A seeding that maps AST to pts would pass a row count check but fail here.
--
-- Run via: python dev/apply_sql.py sql/090_validation/003_spot_checks.sql
-- ============================================================

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE WAREHOUSE NBA_INGEST_WH;

-- ============================================================
-- TABLE: games
-- Spot: 2023 NBA Finals Game 5 (DEN 94, MIA 89 — Denver wins title)
-- Cross-reference: https://www.basketball-reference.com/boxscores/202306120DEN.html
-- ============================================================

SELECT game_id, game_date, home_team_abbr, home_pts, away_team_abbr, away_pts, season_type
FROM ZK_NBA.FLAT.games
WHERE game_date = '2023-06-12';
-- Expected (verified against JB source and BR):
--   game_id  = 42200405
--   home     = DEN  94
--   away     = MIA  89
--   season_type = Playoffs

-- Historical: first game in the dataset
SELECT game_id, game_date, home_team_abbr, home_pts, away_team_abbr, away_pts
FROM ZK_NBA.FLAT.games
ORDER BY game_date ASC
LIMIT 3;
-- Expected: 1946-11-01 games (first NBA season)

-- ============================================================
-- TABLE: player_box_basic
-- Spot: Nikola Jokic, 2023 Finals Game 5
-- Cross-reference: https://www.basketball-reference.com/boxscores/202306120DEN.html
-- ============================================================

SELECT player_name, pts, ast, reb, oreb, dreb, fgm, fga, fg3m, fg3a, ftm, fta, plus_minus
FROM ZK_NBA.FLAT.player_box_basic
WHERE game_id = '42200405'
  AND player_name ILIKE '%Jokic%';
-- Expected (verified against JB_HISTORIC_NBA.PUBLIC.PLAYERSTATISTICS1):
--   pts=28, ast=4, reb=16 (oreb=1, dreb=15)
--   fgm=12, fga=16, fg3m=1, fg3a=3, ftm=3, fta=5
--   plus_minus=+12
-- NOTE: The common memory of this game is "Jokic triple-double" — it was NOT.
--   28 pts, 16 reb, 4 ast. Great game but not a triple-double.

-- Full box score for Finals Game 5, both teams
SELECT player_name, team_abbr, pts, ast, reb, plus_minus
FROM ZK_NBA.FLAT.player_box_basic
WHERE game_id = '42200405'
ORDER BY team_abbr, pts DESC;
-- Expected DEN scorers: Jokic 28, Porter Jr 16, Murray 14, KCP 11, Brown 10
-- Expected MIA scorers: Butler 21, Adebayo 20, Lowry 12, Strus 12, Martin 10

-- All-time scoring leader in a single game (Wilt's 100-point game, 1962-03-02)
SELECT player_name, game_date, team_name, pts, reb, fgm, fga
FROM ZK_NBA.FLAT.player_box_basic
ORDER BY pts DESC
LIMIT 5;
-- Expected: Wilt Chamberlain 100 pts (1962-03-02) as row 1
-- Cross-reference: https://www.basketball-reference.com/boxscores/196203020PHW.html

-- ============================================================
-- TABLE: line_scores
-- Spot: 2023 Finals Game 5 quarter-by-quarter
-- Cross-reference: https://www.basketball-reference.com/boxscores/202306120DEN.html
-- ============================================================

SELECT home_team_abbr, home_q1, home_q2, home_q3, home_q4, home_ot1, home_pts,
       away_team_abbr, away_q1, away_q2, away_q3, away_q4, away_ot1, away_pts
FROM ZK_NBA.FLAT.line_scores
WHERE game_id = '42200405';
-- Expected (verified against JB_HISTORIC_NBA.PUBLIC.LINE_SCORE):
--   DEN: Q1=22, Q2=22, Q3=26, Q4=24, OT=NULL, total=94
--   MIA: Q1=24, Q2=27, Q3=20, Q4=18, OT=NULL, total=89
--   Note: MIA led after Q1 and Q2; DEN outscored them 50-38 in second half.

-- ============================================================
-- TABLE: game_officials
-- Spot: 2023 Finals Game 5 referees (NBA Finals uses 4 officials, not 3)
-- Cross-reference: https://www.basketball-reference.com/boxscores/202306120DEN.html
-- ============================================================

SELECT official_id, first_name, last_name, jersey_num
FROM ZK_NBA.FLAT.game_officials
WHERE game_id = '42200405'
ORDER BY jersey_num;
-- Expected (verified against JB_HISTORIC_NBA.PUBLIC.OFFICIALS):
--   Marc Davis     #8
--   Ed Malloy      #14
--   David Guthrie  #16
--   Josh Tiven     #58
-- NOTE: 4 officials in the Finals. Do NOT assert COUNT=3 here.
-- The typical count per regular-season game is 3; playoff/Finals can be 4.

-- Count distribution: most games should have 3 officials
SELECT official_count, COUNT(*) AS game_count
FROM (
    SELECT game_id, COUNT(*) AS official_count
    FROM ZK_NBA.FLAT.game_officials
    GROUP BY game_id
)
GROUP BY official_count
ORDER BY official_count;
-- Expected: 3 officials for most games (~23K games), 4 for some Finals/playoff games

-- ============================================================
-- TABLE: draft
-- Spot: 2023 NBA Draft top picks
-- Cross-reference: https://www.basketball-reference.com/draft/NBA_2023.html
-- ============================================================

SELECT season, overall_pick, round_number, round_pick, player_name, team_abbr, organization
FROM ZK_NBA.FLAT.draft
WHERE season = 2023 AND overall_pick <= 5
ORDER BY overall_pick;
-- Expected (verified against JB_HISTORIC_NBA.PUBLIC.DRAFT_HISTORY):
--   1  Victor Wembanyama  SAS  Metropolitans 92 (France)
--   2  Brandon Miller     CHA  Alabama
--   3  Scoot Henderson    POR  Ignite (G League)
--   4  Amen Thompson      HOU  Overtime Elite
--   5  Ausar Thompson     DET  Overtime Elite
-- NOTE: Miller was #2, Henderson was #3. A common misremembering swaps them.

-- Historical: first-ever NBA draft (1947)
SELECT season, overall_pick, player_name, team_abbr, organization
FROM ZK_NBA.FLAT.draft
WHERE season = 1947
ORDER BY overall_pick
LIMIT 3;
-- Expected: Clifton McNeeley #1 to Washington Capitols (per BR)

-- ============================================================
-- TABLE: players
-- Spot: Known players with expected bio fields
-- KNOWN DATA QUALITY ISSUE: JB's PLAYERS2 has NULL bio fields for many
-- historical/notable players (verified: LeBron James is all NULLs except name).
-- The players table is most useful for player_id→name mapping and modern players.
-- ============================================================

-- Check: does LeBron James exist in our players table?
SELECT player_id, first_name, last_name, birth_date, country, height_in, weight_lb,
       draft_year, draft_round, draft_pick
FROM ZK_NBA.FLAT.players
WHERE last_name = 'James' AND first_name = 'LeBron';
-- Expected: player_id exists, but bio fields (birth_date, country, height, weight,
--   draft_year/round/pick) may be NULL — this is a known gap in JB's PLAYERS2.
-- Action: supplement from BR player pages in Slice 5 (weekly_meta refresh).

-- Check null rates on key bio columns
SELECT
    COUNT(*) AS total_players,
    SUM(CASE WHEN birth_date IS NULL THEN 1 ELSE 0 END) AS null_birthdate,
    SUM(CASE WHEN height_in IS NULL THEN 1 ELSE 0 END) AS null_height,
    SUM(CASE WHEN country IS NULL THEN 1 ELSE 0 END) AS null_country
FROM ZK_NBA.FLAT.players;
-- Expected: significant nulls — JB's PLAYERS2 has sparse bio coverage.
--   Document the null rate here as the baseline before BR enrichment in Slice 5.
--   A 50%+ null rate on bio fields is expected and known.

-- Modern players (drafted 2020+) should have better coverage
SELECT COUNT(*) AS total, SUM(CASE WHEN birth_date IS NULL THEN 1 ELSE 0 END) AS null_bd
FROM ZK_NBA.FLAT.players WHERE draft_year >= 2020;
-- Expected: lower null rate for recent players

-- ============================================================
-- TABLE: teams
-- Spot: All 30 current teams present; key team facts
-- ============================================================

SELECT COUNT(*) AS total_teams FROM ZK_NBA.FLAT.teams;
-- Expected: 30 (exact)

-- The 5 teams JB's TEAM_DETAILS was missing — should now be present from BR supplement
SELECT abbreviation, full_name, city, year_founded, arena
FROM ZK_NBA.FLAT.teams
WHERE abbreviation IN ('ORL', 'NYK', 'BOS', 'CLE', 'NOP')
ORDER BY abbreviation;
-- Expected: 5 rows, all with city/arena data populated from BR
-- If these still have NULL arena values, the BR supplement step didn't complete.

-- Historical team fact: Celtics founding year
SELECT abbreviation, full_name, year_founded
FROM ZK_NBA.FLAT.teams WHERE abbreviation = 'BOS';
-- Expected: year_founded = 1946

-- ============================================================
-- TABLE: game_inactives
-- Spot: Finals Game 5 — known inactive players
-- ============================================================

SELECT player_id, first_name || ' ' || last_name AS player_name, team_abbr, jersey_num
FROM ZK_NBA.FLAT.game_inactives
WHERE game_id = '42200405'
ORDER BY team_abbr, player_name;
-- Expected: some players listed as inactive for each team
-- Cross-reference against BR box score "Did Not Play" / "Inactive" section
-- Specific expected inactives: check BR for verification before hardcoding here

-- ============================================================
-- TABLE: team_history
-- Spot: Oklahoma City Thunder was previously Seattle SuperSonics
-- ============================================================

SELECT team_id, city, nickname, year_founded, year_active_till
FROM ZK_NBA.FLAT.team_history
WHERE nickname IN ('SuperSonics', 'Thunder')
ORDER BY year_founded;
-- Expected: Seattle SuperSonics (active till ~2008), then OKC Thunder (2008+)

-- ============================================================
-- TABLE: draft_combine
-- Spot: Victor Wembanyama's physical measurements (2023 combine)
-- Cross-reference: https://www.basketball-reference.com/draft/NBA_2023.html combine data
-- ============================================================

SELECT player_name, season, position, height_wo_shoes, height_w_shoes,
       wingspan, standing_reach, weight, standing_vertical_leap, max_vertical_leap
FROM ZK_NBA.FLAT.draft_combine
WHERE season = 2023
  AND player_name ILIKE '%Wembanyama%';
-- Expected: Wembanyama's 2023 combine measurements
-- Height w/ shoes: reportedly ~7'4"; wingspan: ~8'0" — verify exact numbers against BR

-- ============================================================
-- TABLE: play_by_play
-- Spot: Final play of the 2023 NBA Finals (if in the dataset)
-- PBP only covers ~5,337 games (modern seasons) — Finals 2023 may or may not be included
-- ============================================================

SELECT COUNT(*) AS events_in_finals_g5
FROM ZK_NBA.FLAT.play_by_play
WHERE game_id = '42200405';
-- Expected: either 0 (game not in PBP coverage) or ~250-450 events if covered

-- If covered, verify the final event
SELECT event_num, period, clock_game, home_description, visitor_description, score
FROM ZK_NBA.FLAT.play_by_play
WHERE game_id = '42200405'
ORDER BY event_num DESC
LIMIT 5;
-- Expected if populated: final play shows DEN possession or end-of-game event

-- ============================================================
-- CROSS-SOURCE VALIDATION (run for Slice 2, after BR catch-up lands)
-- Compare JB seeded data vs BR scraped data for the same game
-- This catches mapping errors that source-internal checks miss.
-- ============================================================

-- After Slice 2 runs: pick a game that appears in BOTH the JB seed (pre-2023)
-- and the BR catch-up layer (2023+) to verify column mapping is consistent.
-- Use the most recent JB game (2023-06-12) as the JB side.
-- Compare Jokic's stats sourced from JB vs the same game sourced from BR:

SELECT
    source,
    player_name,
    pts, ast, reb, fgm, fga, fg3m, fg3a, ftm, fta, plus_minus
FROM ZK_NBA.FLAT.player_box_basic
WHERE game_id = '42200405'
  AND player_name ILIKE '%Jokic%';
-- Expected: two rows (source='jb_seed' and source='br_scrape') with IDENTICAL numbers.
-- If they differ, the column mapping in one of the flatteners is wrong.
-- This is the gold-standard cross-source check.
