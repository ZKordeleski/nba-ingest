-- Validate the team-id lookup design BEFORE applying it to 1.6M rows.
--
-- We need two lookups:
--   A) name-based:  player_box_basic.team_name  -> team_id (for JB rows)
--   B) abbr-based:  player_box_basic.team_abbr  -> team_id (for BR rows)
--
-- Both have edge cases:
--   - team_history rows for the same franchise overlap on boundary years.
--   - JB's team_name strings might have punctuation/spacing differences vs
--     team_history's city || ' ' || nickname.
--   - BR's abbreviations differ from NBA's for ~4 teams (BRK/BKN, PHO/PHX,
--     CHO/CHA, NOH/NOP historically).
--
-- The output should answer:
--   Q1: How many distinct (team_name) values in player_box_basic (JB rows)?
--   Q2: How many match exactly 1 team_history era for the relevant date?
--       How many match 0?  How many match >1?
--   Q3: Same for (team_abbr) from BR rows against FLAT.teams.
--   Q4: What does team_history actually look like (sample 20 rows)?
--   Q5: What are the BR team_abbr values we need to support?

USE ROLE DEVELOPER_ADMIN;
USE WAREHOUSE NBA_INGEST_WH;
USE DATABASE ZK_NBA;

-- --------------------------------------------------------------------------
-- Q4 first: sample team_history so we understand its shape.
-- --------------------------------------------------------------------------
SELECT team_id, city, nickname, year_founded, year_active_till
FROM FLAT.team_history
ORDER BY city, year_founded
LIMIT 20;

-- How many rows total?
SELECT COUNT(*) AS team_history_rows FROM FLAT.team_history;

-- --------------------------------------------------------------------------
-- Q1: distinct team_name values in JB-seeded player_box_basic.
-- --------------------------------------------------------------------------
SELECT COUNT(DISTINCT team_name) AS distinct_jb_team_names
FROM FLAT.player_box_basic
WHERE source = 'jb_seed';

-- Sample 20 distinct ones.
SELECT DISTINCT team_name
FROM FLAT.player_box_basic
WHERE source = 'jb_seed'
ORDER BY team_name
LIMIT 20;

-- --------------------------------------------------------------------------
-- Q2: how well does the name-based lookup match team_history?
-- For each game's team, get the year and try to resolve team_id.
-- --------------------------------------------------------------------------
WITH jb_team_year AS (
    SELECT DISTINCT
        team_name,
        EXTRACT(YEAR FROM game_date) AS year
    FROM FLAT.player_box_basic
    WHERE source = 'jb_seed'
      AND team_name IS NOT NULL
),
matched AS (
    SELECT
        jb.team_name,
        jb.year,
        COUNT(DISTINCT th.team_id) AS n_team_ids_matched
    FROM jb_team_year jb
    LEFT JOIN FLAT.team_history th
      ON TRIM(th.city) || ' ' || TRIM(th.nickname) = jb.team_name
     AND jb.year BETWEEN th.year_founded
                     AND COALESCE(th.year_active_till, 9999)
    GROUP BY jb.team_name, jb.year
)
SELECT
    CASE n_team_ids_matched
        WHEN 0 THEN '0_no_match'
        WHEN 1 THEN '1_exact'
        ELSE 'N_multi'
    END AS bucket,
    COUNT(*) AS distinct_team_year_pairs
FROM matched
GROUP BY 1
ORDER BY 1;

-- Show 20 unmatched cases so we see what's wrong.
WITH jb_team_year AS (
    SELECT DISTINCT
        team_name,
        EXTRACT(YEAR FROM game_date) AS year
    FROM FLAT.player_box_basic
    WHERE source = 'jb_seed'
      AND team_name IS NOT NULL
),
unmatched AS (
    SELECT jb.team_name, jb.year
    FROM jb_team_year jb
    LEFT JOIN FLAT.team_history th
      ON TRIM(th.city) || ' ' || TRIM(th.nickname) = jb.team_name
     AND jb.year BETWEEN th.year_founded
                     AND COALESCE(th.year_active_till, 9999)
    WHERE th.team_id IS NULL
)
SELECT team_name, MIN(year) AS first_year_seen, MAX(year) AS last_year_seen, COUNT(*) AS years
FROM unmatched
GROUP BY team_name
ORDER BY years DESC, team_name
LIMIT 20;

-- --------------------------------------------------------------------------
-- Q3: distinct team_abbr values in BR-scraped player_box_basic.
-- --------------------------------------------------------------------------
SELECT team_abbr, COUNT(*) AS row_count
FROM FLAT.player_box_basic
WHERE source = 'br_scrape' AND team_abbr IS NOT NULL
GROUP BY team_abbr
ORDER BY team_abbr;

-- Does each BR abbr have a match in FLAT.teams?
WITH br_abbrs AS (
    SELECT DISTINCT team_abbr
    FROM FLAT.player_box_basic
    WHERE source = 'br_scrape' AND team_abbr IS NOT NULL
)
SELECT
    br.team_abbr AS br_abbr,
    t.team_id    AS matched_team_id,
    t.full_name  AS matched_team
FROM br_abbrs br
LEFT JOIN FLAT.teams t
       ON t.abbreviation = br.team_abbr
ORDER BY br.team_abbr;
