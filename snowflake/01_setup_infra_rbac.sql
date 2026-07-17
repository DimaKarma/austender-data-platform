/* =====================================================================
   01_setup_infra_rbac.sql
   AusTender Data Platform — infrastructure + RBAC
   Run as ACCOUNTADMIN (or SECURITYADMIN + SYSADMIN).

   What it does:
     1. Virtual warehouses (compute).
     2. Database austender_db + the three Medallion schemas: BRONZE / SILVER / GOLD.
     3. Role model following Snowflake RBAC best practice:
          - functional roles: DE (engineer), ANALYST (reads GOLD), CI (pipeline)
          - roles granted to SYSADMIN (hierarchy) and to the user.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;

-- 1. Compute -----------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS austender_wh
    WITH WAREHOUSE_SIZE = 'XSMALL'
         AUTO_SUSPEND = 60
         AUTO_RESUME = TRUE
         INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Compute for the AusTender ETL/ELT (dbt + Python loader)';

-- A separate warehouse for CI so the workloads stay isolated
CREATE WAREHOUSE IF NOT EXISTS austender_ci_wh
    WITH WAREHOUSE_SIZE = 'XSMALL'
         AUTO_SUSPEND = 60
         AUTO_RESUME = TRUE
         INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Compute for CI/CD dbt runs';

-- 2. Database + Medallion schemas --------------------------------------
CREATE DATABASE IF NOT EXISTS austender_db
    COMMENT = 'AusTender — Australian federal contracts';

CREATE SCHEMA IF NOT EXISTS austender_db.bronze
    COMMENT = 'Raw layer: source data as-is, no transformations';
CREATE SCHEMA IF NOT EXISTS austender_db.silver
    COMMENT = 'Cleansed layer: typing, deduplication, standardization';
CREATE SCHEMA IF NOT EXISTS austender_db.gold
    COMMENT = 'Curated layer: star schema (dim/fct) — the model, not what BI reads';
CREATE SCHEMA IF NOT EXISTS austender_db.mart
    COMMENT = 'Consumption layer: reporting views with caveats applied; what BI reads';

-- 3. RBAC --------------------------------------------------------------
USE ROLE SECURITYADMIN;

-- 3.1 Functional roles
CREATE ROLE IF NOT EXISTS austender_de      COMMENT = 'Data Engineer: full access to every layer';
CREATE ROLE IF NOT EXISTS austender_analyst COMMENT = 'Analyst: read-only access to MART';
CREATE ROLE IF NOT EXISTS austender_ci      COMMENT = 'Service role for CI/CD (dbt build)';

-- 3.2 Hierarchy: functional roles roll up to SYSADMIN
GRANT ROLE austender_de      TO ROLE SYSADMIN;
GRANT ROLE austender_analyst TO ROLE SYSADMIN;
GRANT ROLE austender_ci      TO ROLE SYSADMIN;

-- 3.3 Grants for DE (engineer: writes to every layer) ------------------
GRANT USAGE ON WAREHOUSE austender_wh TO ROLE austender_de;
GRANT USAGE ON DATABASE  austender_db TO ROLE austender_de;
GRANT USAGE ON ALL SCHEMAS IN DATABASE austender_db TO ROLE austender_de;
GRANT ALL   ON SCHEMA austender_db.bronze TO ROLE austender_de;
GRANT ALL   ON SCHEMA austender_db.silver TO ROLE austender_de;
GRANT ALL   ON SCHEMA austender_db.gold   TO ROLE austender_de;
GRANT ALL   ON SCHEMA austender_db.mart   TO ROLE austender_de;
-- Grants on both existing and future objects
GRANT ALL ON ALL TABLES    IN DATABASE austender_db TO ROLE austender_de;
GRANT ALL ON FUTURE TABLES IN DATABASE austender_db TO ROLE austender_de;
GRANT ALL ON ALL VIEWS     IN DATABASE austender_db TO ROLE austender_de;
GRANT ALL ON FUTURE VIEWS  IN DATABASE austender_db TO ROLE austender_de;

-- 3.4 Grants for CI (same profile, its own warehouse) -----------------
GRANT USAGE ON WAREHOUSE austender_ci_wh TO ROLE austender_ci;
GRANT USAGE ON DATABASE  austender_db TO ROLE austender_ci;
-- CI builds into its own CI_SILVER/CI_GOLD/CI_MART schemas (see the
-- generate_schema_name macro) so a PR run never rebuilds the BI-facing GOLD/MART.
-- It creates them on the fly, so it needs CREATE SCHEMA on the database.
GRANT CREATE SCHEMA ON DATABASE austender_db TO ROLE austender_ci;
GRANT USAGE ON ALL SCHEMAS IN DATABASE austender_db TO ROLE austender_ci;
GRANT ALL ON SCHEMA austender_db.bronze TO ROLE austender_ci;
GRANT ALL ON SCHEMA austender_db.silver TO ROLE austender_ci;
GRANT ALL ON SCHEMA austender_db.gold   TO ROLE austender_ci;
GRANT ALL ON SCHEMA austender_db.mart   TO ROLE austender_ci;
GRANT ALL ON ALL TABLES    IN DATABASE austender_db TO ROLE austender_ci;
GRANT ALL ON FUTURE TABLES IN DATABASE austender_db TO ROLE austender_ci;
GRANT ALL ON ALL VIEWS     IN DATABASE austender_db TO ROLE austender_ci;
GRANT ALL ON FUTURE VIEWS  IN DATABASE austender_db TO ROLE austender_ci;

-- 3.5 Grants for ANALYST (least privilege: read MART only, not the raw star)
--     The analyst reads the consumption layer, where the caveats are already
--     applied. GOLD is deliberately NOT granted: the mart views reach it through
--     ownership chaining (view and gold tables share owner austender_de), so the
--     analyst can query the views without ever touching the star directly, and
--     cannot run a naive SUM over fct_contracts.
GRANT USAGE ON WAREHOUSE austender_wh TO ROLE austender_analyst;
GRANT USAGE ON DATABASE  austender_db TO ROLE austender_analyst;
GRANT USAGE ON SCHEMA    austender_db.mart TO ROLE austender_analyst;
GRANT SELECT ON ALL VIEWS     IN SCHEMA austender_db.mart TO ROLE austender_analyst;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA austender_db.mart TO ROLE austender_analyst;
GRANT SELECT ON ALL TABLES    IN SCHEMA austender_db.mart TO ROLE austender_analyst;
GRANT SELECT ON FUTURE TABLES IN SCHEMA austender_db.mart TO ROLE austender_analyst;

-- 3.6 Grant the roles to the current user (REPLACE YOUR_USERNAME) ------
--     Find your name with: SELECT CURRENT_USER();
--     bootstrap.py substitutes this placeholder automatically.
GRANT ROLE austender_de      TO USER YOUR_USERNAME;
GRANT ROLE austender_analyst TO USER YOUR_USERNAME;
-- austender_ci is what GitHub Actions connects as (dbt build --target ci).
-- In a production account CI would authenticate as its own service user; here
-- the workflow reuses these credentials, so the role must be granted to them —
-- without this, `dbt build --target ci` cannot connect at all.
GRANT ROLE austender_ci      TO USER YOUR_USERNAME;

-- Smoke check
USE ROLE austender_de;
USE WAREHOUSE austender_wh;
USE DATABASE austender_db;
SELECT 'Infrastructure and RBAC are ready' AS status;
