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
    -- one contract = one row; on duplicates keep the latest load
    select *,
        row_number() over (
            partition by contract_id
            order by loaded_at desc nulls last
        ) as _rn
    from staged
    where contract_id is not null
),

cleaned as (
    select
        contract_id,
        agency_name,
        supplier_name,

        -- Business identifiers, derived from the NULL-able ABNs. These read the
        -- input columns, so they see the real ABN or NULL — never the 'UNKNOWN'
        -- placeholder aliased below. The key must be the identifier; 'UNKNOWN'
        -- is only what an analyst reads.
        {{ supplier_business_key('supplier_abn', 'supplier_name') }} as supplier_business_key,
        {{ agency_legal_entity_key('agency_abn', 'agency_name') }}   as agency_legal_entity_key,

        coalesce(agency_abn, 'UNKNOWN')            as agency_abn,
        coalesce(supplier_abn, 'UNKNOWN')          as supplier_abn,
        category_name,
        coalesce(category_unspsc, 'UNKNOWN')       as category_unspsc,
        coalesce(procurement_method, 'Unknown')    as procurement_method,
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
    where _rn = 1
      and contract_value is not null
      and contract_value > 0
)

select * from cleaned
