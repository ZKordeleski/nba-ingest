-- Internal stage for nba-ingest: landing zone for BR-scraped NDJSON files.
-- PUT uploads files here; COPY INTO / MERGE reads from here.
-- Same pattern as wow-ingest's INGEST_STAGE.
--
-- Run after 001_bootstrap.sql.

USE ROLE DEVELOPER_ADMIN;
USE DATABASE ZK_NBA;
USE SCHEMA RAW;
USE WAREHOUSE NBA_INGEST_WH;

CREATE STAGE IF NOT EXISTS ZK_NBA.RAW.INGEST_STAGE
    FILE_FORMAT = (TYPE = 'JSON' STRIP_OUTER_ARRAY = FALSE)
    COMMENT = 'Landing zone for Basketball-Reference NDJSON files. daily_settle.py PUTs here; MERGE reads from here.'
;

-- Named JSON file format. SELECT FROM @stage requires a *named* FILE_FORMAT
-- reference (inline `(TYPE = 'JSON')` is rejected as non-constant). All
-- MERGE statements that read staged JSON files reference this by name.
CREATE OR REPLACE FILE FORMAT ZK_NBA.RAW.JSON_FF
    TYPE = 'JSON'
    COMMENT = 'Reusable JSON file format for SELECT FROM @stage in MERGE statements.';

-- Verify
SHOW STAGES IN SCHEMA ZK_NBA.RAW;
SHOW FILE FORMATS IN SCHEMA ZK_NBA.RAW;
