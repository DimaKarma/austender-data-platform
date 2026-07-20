/* =====================================================================
   01_setup_infra_rbac.sql
   AusTender Data Platform — infrastructure + RBAC
   Run as ACCOUNTADMIN (or SECURITYADMIN + SYSADMIN).

   What it does:
     1. Virtual warehouses (compute).
     2. Database austender_db + Medallion schemas: BRONZE / SILVER / GOLD / MART.
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

-- A separate warehouse for BI so analyst queries never queue behind the ETL.
CREATE WAREHOUSE IF NOT EXISTS austender_bi_wh
    WITH WAREHOUSE_SIZE = 'XSMALL'
         AUTO_SUSPEND = 60
         AUTO_RESUME = TRUE
         INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Compute for analyst / BI queries against the Mart';

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

-- 3.4 Grants for CI (least privilege) ---------------------------------
--     CI builds into its own CI_SILVER/CI_GOLD/CI_MART schemas, which it
--     CREATEs and therefore OWNS — so it needs no grants on them. Its only
--     inputs are the shared BRONZE sources. It is deliberately given NOTHING on
--     the prod SILVER/GOLD/MART, so the isolation is structural (grants), not
--     just behavioural (the generate_schema_name macro): even a broken macro
--     could not let a PR overwrite the BI-facing star, because the role cannot
--     write there.
GRANT USAGE ON WAREHOUSE austender_ci_wh TO ROLE austender_ci;
GRANT USAGE ON DATABASE  austender_db TO ROLE austender_ci;
GRANT CREATE SCHEMA ON DATABASE austender_db TO ROLE austender_ci;
GRANT USAGE  ON SCHEMA austender_db.bronze TO ROLE austender_ci;
GRANT SELECT ON ALL TABLES    IN SCHEMA austender_db.bronze TO ROLE austender_ci;
GRANT SELECT ON FUTURE TABLES IN SCHEMA austender_db.bronze TO ROLE austender_ci;

-- 3.5 Grants for ANALYST (least privilege: read MART only, not the raw star)
--     The analyst reads the consumption layer, where the caveats are already
--     applied. GOLD is deliberately NOT granted: the mart views reach it through
--     ownership chaining (view and gold tables share owner austender_de), so the
--     analyst can query the views without ever touching the star directly, and
--     cannot run a naive SUM over fct_contracts.
GRANT USAGE ON WAREHOUSE austender_bi_wh TO ROLE austender_analyst;
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
-- GitHub Actions connects as its own service user austender_ci_svc (key-pair),
-- created separately with the austender_ci role. Granting austender_ci to the
-- human user too only enables local `dbt build --target ci` testing.
GRANT ROLE austender_ci      TO USER YOUR_USERNAME;

-- 4. Data governance: column masking + row access policies -----------------
--
--    HONEST FRAMING: AusTender is PUBLIC data — an ABN is an open business
--    identifier, not personal data — so the policies below protect nothing real.
--    They demonstrate the Snowflake governance MECHANISM on this dataset. In a
--    regulated-PII setting (e.g. health-insurance member data) you would apply
--    the same Dynamic Data Masking to SSNs, dates of birth and diagnoses, and the
--    same Row Access Policy to restrict rows by member, region or entitlement.
--
--    Owned by austender_de (created here as that role) so the dbt post-hook that
--    attaches the masking policy — mart runs as austender_de both locally and on
--    the deploy button — can apply it without an extra APPLY grant.
USE ROLE austender_de;
USE SCHEMA austender_db.mart;

-- 4.1 Dynamic Data Masking: engineers see the raw supplier ABN; every other role
--     (the BI analyst) sees it partially masked, last 3 digits preserved so the
--     format stays recognizable. Attached to mart.rpt_contracts.supplier_abn by a
--     post_hook on that model (a dbt CREATE OR REPLACE VIEW would otherwise drop
--     the attachment on every build).
CREATE MASKING POLICY IF NOT EXISTS mask_supplier_abn AS (val STRING) RETURNS STRING ->
    CASE
        WHEN IS_ROLE_IN_SESSION('AUSTENDER_DE') THEN val          -- engineers/admins: raw
        WHEN val IS NULL OR val = 'UNKNOWN' THEN val              -- sentinel, nothing to hide
        ELSE 'XXXXXXXX' || RIGHT(val, 3)                          -- others: partial mask
    END;
-- The post_hook effectively runs, on every build of rpt_contracts:
--   ALTER VIEW mart.rpt_contracts
--     MODIFY COLUMN supplier_abn SET MASKING POLICY mart.mask_supplier_abn FORCE;

-- 4.2 Row Access Policy (illustrative — created, deliberately NOT applied, so the
--     analyst keeps full visibility for spend analysis). The pattern: a boolean
--     per row per role. Here a hypothetical external-partner role would see only
--     rows already attributable to a named supplier; engineers see everything.
CREATE ROW ACCESS POLICY IF NOT EXISTS rap_contracts_attributable_only
    AS (is_attributable BOOLEAN) RETURNS BOOLEAN ->
        IS_ROLE_IN_SESSION('AUSTENDER_DE') OR is_attributable;
-- Apply it (when such a role exists) with:
--   ALTER VIEW mart.rpt_contracts ADD ROW ACCESS POLICY mart.rap_contracts_attributable_only
--     ON (is_attributable);

-- Smoke check
USE ROLE austender_de;
USE WAREHOUSE austender_wh;
USE DATABASE austender_db;
SELECT 'Infrastructure, RBAC and governance policies are ready' AS status;
