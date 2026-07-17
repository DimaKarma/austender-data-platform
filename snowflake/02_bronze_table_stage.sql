/* =====================================================================
   02_bronze_table_stage.sql
   Bronze table and internal stage matching the real AustralianFederalContracts.csv
   CSV columns (15):
     agencyname, value, suppliername, description, publishdate,
     contractstart, contractend, procurementmethod, category,
     agencyabn, supplierabn, categoryunspsc, cnid, supplierid, sourceurl

   Run as the austender_de role.
   ===================================================================== */

USE ROLE austender_de;
USE WAREHOUSE austender_wh;
USE DATABASE austender_db;
USE SCHEMA bronze;

-- Bronze principle: load everything as STRING, no typing or logic.
CREATE TABLE IF NOT EXISTS raw_contract_data (
    agencyname         STRING,
    value              STRING,
    suppliername       STRING,
    description        STRING,
    publishdate        STRING,
    contractstart      STRING,
    contractend        STRING,
    procurementmethod  STRING,
    category           STRING,
    agencyabn          STRING,
    supplierabn        STRING,
    categoryunspsc     STRING,
    cnid               STRING,
    supplierid         STRING,
    sourceurl          STRING,
    -- audit columns (a common Bronze/lineage practice)
    _loaded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file       STRING
);

-- Named CSV file format, reused by COPY
CREATE FILE FORMAT IF NOT EXISTS ff_csv_austender
    TYPE = 'CSV'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL', 'null')
    EMPTY_FIELD_AS_NULL = TRUE
    ENCODING = 'UTF8';

-- Internal stage (the equivalent of an S3 bucket for uploads)
CREATE STAGE IF NOT EXISTS austender_stage
    FILE_FORMAT = ff_csv_austender
    COMMENT = 'Landing stage for the AusTender CSV';

SELECT 'Bronze table and stage are ready' AS status;
