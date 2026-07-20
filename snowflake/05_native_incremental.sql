/*
  05_native_incremental.sql
  ----------------------------------------------------------------------------
  Snowflake-NATIVE incremental patterns, shown next to the Python + dbt path.

  The rest of this project does delta ingestion in Python (a MERGE loader, see
  ingestion/load_to_bronze.py) and incremental transformation in dbt
  (fct_contracts). That is a portable, testable, version-controlled approach and
  it is the production path here.

  This script demonstrates the two Snowflake-native alternatives a Snowflake
  Developer is expected to reach for, so the trade-off is explicit rather than
  implied:

    1. STREAM + TASK  — change-data-capture on a table (Stream) consumed on a
       schedule (Task) with a MERGE. Imperative, fine-grained, good when the
       transform is procedural or must run the moment new data lands.
    2. DYNAMIC TABLE  — declarative: you write the target query, Snowflake keeps
       it incrementally fresh to a TARGET_LAG. Good for straightforward
       transforms/aggregates where you want no orchestration code at all.

  When to use which (the point of showing all three):
    - dbt            : complex multi-model DAGs, tests, docs, CI/CD, portability.
    - Stream + Task  : event-style "process what changed" inside Snowflake, or
                       procedural logic that does not fit a single SELECT.
    - Dynamic Table  : a single declarative transform kept fresh with no code.

  Objects live in a dedicated NATIVE_DEMO schema so they never collide with the
  dbt-managed SILVER/GOLD models (which dbt drops and recreates).

  Run once as ACCOUNTADMIN (grants + schema); the objects are then owned by
  austender_de. Idempotent — safe to re-run.
  ----------------------------------------------------------------------------
*/

-- 1. Privileges the native path needs (run as ACCOUNTADMIN) ------------------
USE ROLE ACCOUNTADMIN;

-- Running a Task requires EXECUTE TASK at the account level, granted to the role
-- that owns the task. (EXECUTE MANAGED TASK would be needed only for serverless
-- tasks; this demo uses a warehouse-backed task.)
GRANT EXECUTE TASK ON ACCOUNT TO ROLE austender_de;

CREATE SCHEMA IF NOT EXISTS austender_db.native_demo;
GRANT ALL ON SCHEMA austender_db.native_demo TO ROLE austender_de;

-- 2. Build the native objects as the engineer role ---------------------------
USE ROLE austender_de;
USE WAREHOUSE austender_wh;
USE SCHEMA austender_db.native_demo;

/* ---- Pattern 1: Stream + Task -------------------------------------------- */

-- A Stream records the row-level changes (insert / update / delete) applied to
-- bronze.raw_contract_data since it was last consumed. SHOW_INITIAL_ROWS = FALSE
-- means "changes from now on", not a seed of the existing 241k rows.
CREATE OR REPLACE STREAM raw_contract_changes
    ON TABLE austender_db.bronze.raw_contract_data
    SHOW_INITIAL_ROWS = FALSE;

-- The native Silver target the Task maintains. A trimmed, typed mirror of the
-- dbt silver model — enough to show the pattern end to end.
CREATE TABLE IF NOT EXISTS slv_contracts_native (
    contract_id     STRING,
    agency_name     STRING,
    supplier_name   STRING,
    contract_value  NUMBER(18, 2),
    publish_date    DATE,
    loaded_at       TIMESTAMP_NTZ,
    _merged_at      TIMESTAMP_NTZ
);

-- The Task: whenever the Stream has data, MERGE the net change per contract into
-- the target. WHEN SYSTEM$STREAM_HAS_DATA gates the schedule so the warehouse
-- only wakes when there is actually something to process.
--
-- Stream metadata: an UPDATE surfaces as a DELETE (old) + INSERT (new) pair,
-- both with METADATA$ISUPDATE = TRUE; a pure insert/delete is a single row with
-- ISUPDATE = FALSE. Ranking each key by loaded_at desc keeps the row that
-- represents its final state (the INSERT-new for an update, the lone row
-- otherwise), so one MERGE handles inserts, updates and deletes.
CREATE OR REPLACE TASK tsk_merge_contract_changes
    WAREHOUSE = austender_wh
    SCHEDULE = '60 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('raw_contract_changes')
AS
    MERGE INTO slv_contracts_native AS t
    USING (
        SELECT
            cnid                                    AS contract_id,
            agencyname                              AS agency_name,
            suppliername                            AS supplier_name,
            try_to_number(value, 18, 2)             AS contract_value,
            try_to_date(publishdate, 'YYYY-MM-DD')  AS publish_date,
            _loaded_at                              AS loaded_at,
            metadata$action                         AS change_action,
            metadata$isupdate                       AS is_update
        FROM raw_contract_changes
        WHERE cnid IS NOT NULL
        QUALIFY row_number() OVER (
            PARTITION BY cnid ORDER BY _loaded_at DESC NULLS LAST) = 1
    ) AS s
    ON t.contract_id = s.contract_id
    -- A net delete (a lone DELETE row, not the old half of an update) removes it.
    WHEN MATCHED AND s.change_action = 'DELETE' AND s.is_update = FALSE THEN DELETE
    WHEN MATCHED THEN UPDATE SET
        agency_name = s.agency_name, supplier_name = s.supplier_name,
        contract_value = s.contract_value, publish_date = s.publish_date,
        loaded_at = s.loaded_at, _merged_at = current_timestamp()
    WHEN NOT MATCHED AND s.change_action = 'INSERT' THEN
        INSERT (contract_id, agency_name, supplier_name, contract_value,
                publish_date, loaded_at, _merged_at)
        VALUES (s.contract_id, s.agency_name, s.supplier_name, s.contract_value,
                s.publish_date, s.loaded_at, current_timestamp());

-- Tasks are created SUSPENDED. Resume to activate the schedule; suspend to stop
-- it (and any credit use) — a gated task costs almost nothing while idle, but a
-- trial account should not leave compute armed by accident.
--   ALTER TASK tsk_merge_contract_changes RESUME;
--   ALTER TASK tsk_merge_contract_changes SUSPEND;

/* ---- Pattern 2: Dynamic Table -------------------------------------------- */

-- The declarative alternative: one SELECT, kept incrementally fresh by Snowflake
-- to within TARGET_LAG, with no Stream and no Task to wire up. Suspend it when
-- not in use so scheduled refreshes do not spend credits on the trial.
--
-- This is a raw aggregate over bronze to demonstrate the DT maintenance mechanism;
-- it therefore still contains amendment double-counting. The amendment-correct,
-- deduplicated spend is the dbt fact/mart's job (fct_contracts, rpt_agency_spend),
-- not this object's.
CREATE OR REPLACE DYNAMIC TABLE dt_agency_spend
    TARGET_LAG = '1 hour'
    WAREHOUSE = austender_wh
AS
    SELECT
        agencyname                    AS agency_name,
        count(*)                      AS contract_count,
        sum(try_to_number(value, 18, 2)) AS total_value
    FROM austender_db.bronze.raw_contract_data
    GROUP BY agencyname;

SELECT 'Native incremental objects created in NATIVE_DEMO' AS status;
