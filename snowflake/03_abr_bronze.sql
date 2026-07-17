/* =====================================================================
   03_abr_bronze.sql
   Bronze table and stage for the second source: the Australian Business
   Register bulk extract.

   Why the table is created here and not only by the loader: the dbt model
   stg_abr_entity depends on this source unconditionally, while loading the ABR
   is optional (it downloads ~944MB and streams 12.5GB of XML). Creating the
   table empty keeps `dbt build` working on an account that has never loaded the
   ABR — the enrichment columns simply come back NULL and
   supplier_abn_is_placeholder is false, rather than the build failing.

   Populate it with: python ingestion/load_abr_to_bronze.py
   (or: python bootstrap.py --with-abr)

   Source: https://data.gov.au/data/dataset/abn-bulk-extract
   Licence: Creative Commons Attribution 3.0 Australia.

   Run as the austender_de role.
   ===================================================================== */

USE ROLE austender_de;
USE WAREHOUSE austender_wh;
USE DATABASE austender_db;
USE SCHEMA bronze;

-- Bronze principle: everything as STRING, no typing or logic.
CREATE TABLE IF NOT EXISTS raw_abr_entity (
    abn                  STRING,
    abn_status           STRING,   -- ACT or CAN; cancelled ABNs are kept
    abn_status_from_date STRING,
    entity_type_ind      STRING,   -- e.g. PRV, CGE, IND
    entity_type_text     STRING,   -- e.g. 'Commonwealth Government Entity'
    entity_name          STRING,   -- one of the entity's names (see name_type)
    name_type            STRING,   -- MAIN (canonical) / TRD (trading) / OTN / ...
    state                STRING,
    postcode             STRING,
    -- audit columns, same convention as raw_contract_data
    _loaded_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file         STRING
);

CREATE STAGE IF NOT EXISTS abr_stage
    FILE_FORMAT = ff_csv_austender
    COMMENT = 'Landing stage for the ABR bulk extract CSV';

SELECT 'ABR bronze table and stage are ready' AS status;
