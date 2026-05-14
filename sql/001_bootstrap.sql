-- nba-ingest bootstrap: database, schemas, warehouse.
-- Run this once against the modeler team Snowflake account.
-- Assumes DEVELOPER_ADMIN role.
--
-- Account: ndsoebe-rai_int_modeler_team_aws_us_west_2_consumer
-- Run via Snowsight or: python dev/apply_sql.py sql/001_bootstrap.sql

USE ROLE DEVELOPER_ADMIN;

CREATE DATABASE IF NOT EXISTS ZK_NBA
    COMMENT = 'NBA stats pipeline. Data: Basketball-Reference.com (see LICENSES.md). Contact: zack.kordeleski@relational.ai';

CREATE SCHEMA IF NOT EXISTS ZK_NBA.RAW
    COMMENT = 'Raw scraped payloads — exactly what Basketball-Reference returned. Append-only. Used for re-flattening if FLAT schema changes.';

CREATE SCHEMA IF NOT EXISTS ZK_NBA.FLAT
    COMMENT = 'Flattened relational tables. No derived metrics — agent computes at query time. Source: JB_HISTORIC_NBA seed (1946-2025) + Basketball-Reference (2023-present).';

CREATE SCHEMA IF NOT EXISTS ZK_NBA.DERIVED
    COMMENT = 'Reserved for future user/agent-authored views and derived concepts.';

CREATE WAREHOUSE IF NOT EXISTS NBA_INGEST_WH
    WITH WAREHOUSE_SIZE = XSMALL
         AUTO_SUSPEND = 60
         AUTO_RESUME = TRUE
         INITIALLY_SUSPENDED = TRUE
         COMMENT = 'Compute for nba-ingest pipelines. XSMALL is sufficient for daily settle job. The JB seed CTASs may be slightly slow but complete in a few minutes.';

-- Verify
SHOW DATABASES LIKE 'ZK_NBA';
SHOW SCHEMAS IN DATABASE ZK_NBA;
SHOW WAREHOUSES LIKE 'NBA_INGEST_WH';
