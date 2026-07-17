/* =====================================================================
   04_resource_monitor.sql
   A credit guard on the trial account.

   The warehouses are XSMALL (1 credit/hour), but nothing stopped a runaway
   query or a stuck loop from burning the trial's credits with no ceiling. This
   caps monthly usage and suspends compute before the trial is exhausted.

   50 credits/month is ~50 hours of XSMALL compute — generous for this project
   (a full rebuild is seconds), so it only bites on genuinely runaway usage.

   Resource monitors are ACCOUNTADMIN-only.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;

CREATE RESOURCE MONITOR IF NOT EXISTS austender_rm
    WITH CREDIT_QUOTA = 50
         FREQUENCY = MONTHLY
         START_TIMESTAMP = IMMEDIATELY
         TRIGGERS
             ON 80  PERCENT DO NOTIFY            -- warn, keep running
             ON 100 PERCENT DO SUSPEND           -- let running queries finish, then stop
             ON 110 PERCENT DO SUSPEND_IMMEDIATE; -- hard stop

-- Attach to both project warehouses. COMPUTE_WH and the Snowflake-managed
-- warehouses are left alone.
ALTER WAREHOUSE austender_wh    SET RESOURCE_MONITOR = austender_rm;
ALTER WAREHOUSE austender_ci_wh SET RESOURCE_MONITOR = austender_rm;

SELECT 'Resource monitor and warehouse guards are ready' AS status;
