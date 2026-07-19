/*
  slv_contracts — Silver (cleansed) layer.
  Business cleansing:
    * deduplicate by contract_id (keep the most recent load);
    * COALESCE the NULLs (procurement_method is ~93% empty in the source);
    * drop invalid rows (no contract_id, or value <= 0).
  Materialized as a table.
*/
{{ config(materialized='table') }}

with staged as (
    select * from {{ ref('stg_contracts') }}
),

deduped as (
    -- one contract = one row; on duplicates keep the latest load.
    -- loaded_at alone is not a deterministic tiebreak: it is assigned once per
    -- COPY, so all rows from one load share it, and two rows with the same
    -- contract_id in a single file would pick a random winner. The extra sort
    -- keys give a total, stable order. (cnid is unique in today's file, so this
    -- never fires — it is a guard for intra-file duplicates under delta loads.)
    select
        *,
        row_number() over (
            partition by contract_id
            order by
                loaded_at desc nulls last,
                contract_value desc nulls last,
                contract_end_date desc nulls last,
                coalesce(source_url, '')
        ) as _rn
    from staged
    where contract_id is not null
),

cleaned as (
    select
        contract_id,
        -- Coalesce the name fields too, not just the codes. The fact generates a
        -- surrogate key for every contract, but the dimensions filtered out rows
        -- with a null name — so a null name would leave the fact pointing at a
        -- dimension row that does not exist. Bucketing nulls as 'Unknown' keeps
        -- that contract's spend attributable instead of dropping it, and keeps
        -- fact and dimensions consistent by construction. (0 null names today,
        -- so this is output-preserving now and a guard against drift.)
        coalesce(agency_name, 'Unknown') as agency_name,
        coalesce(agency_abn, 'UNKNOWN') as agency_abn,
        coalesce(supplier_name, 'Unknown') as supplier_name,
        coalesce(supplier_abn, 'UNKNOWN') as supplier_abn,
        coalesce(category_name, 'Unknown') as category_name,
        coalesce(category_unspsc, 'UNKNOWN') as category_unspsc,
        coalesce(procurement_method, 'Unknown') as procurement_method,
        contract_description,
        source_url,
        contract_value,
        publish_date,
        contract_start_date,
        contract_end_date,
        -- derived measure: contract duration in days
        datediff('day', contract_start_date, contract_end_date) as duration_days,
        loaded_at
    from deduped
    where
        _rn = 1
        and contract_value is not null
        and contract_value > 0
)

select * from cleaned
