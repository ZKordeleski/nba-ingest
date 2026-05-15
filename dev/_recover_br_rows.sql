-- Recover the 104K BR-scraped player_box_basic rows that were TRUNCATEd
-- when we re-ran the seed (which is non-source-aware).
--
-- Strategy: use Snowflake time-travel to query the table state from ~20m ago,
-- pull out the BR rows, and INSERT them back into the live table.
--
-- Snowflake AT(OFFSET => -N) reads the table state from N seconds in the past.
-- Default retention is 1 day on standard accounts — plenty for this recovery.

USE ROLE DEVELOPER_ADMIN;
USE WAREHOUSE NBA_INGEST_WH;
USE DATABASE ZK_NBA;

-- First confirm the BR rows existed ~25 minutes ago.
SELECT
    source,
    COUNT(*) AS row_count,
    MIN(game_date) AS min_date,
    MAX(game_date) AS max_date
FROM FLAT.player_box_basic AT(OFFSET => -1500)
GROUP BY source;

-- Recover them.
INSERT INTO FLAT.player_box_basic
SELECT *
FROM FLAT.player_box_basic AT(OFFSET => -1500)
WHERE source = 'br_scrape';

-- Confirm restored.
SELECT source, COUNT(*) AS row_count
FROM FLAT.player_box_basic
GROUP BY source;
