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

-- Verify
SHOW STAGES IN SCHEMA ZK_NBA.RAW;
