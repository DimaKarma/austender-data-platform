/*
  fct_contracts — the "Contract" fact table.
  Grain: one row = one contract_id.
  Incremental: re-runs process only rows ingested since the last build.
  Foreign keys to every dimension use surrogate keys built with the same
  formula as the dim models.
*/
{{ config(
    materialized='incremental',
    unique_key='contract_id',
    incremental_strategy='merge'
) }}

with contracts as (
    select * from {{ ref('slv_contracts') }}

    {% if is_incremental() %}
      -- High-water mark on the ingestion timestamp, NOT on publish_date.
      --
      -- Filtering by a business date drops two classes of rows for good:
      --   * late arrivals — a contract published before the current maximum but
      --     ingested afterwards is never seen again;
      --   * amendments — an updated contract keeps its original publish_date, so
      --     it can never clear the watermark. That silently defeats
      --     unique_key + merge, which exist precisely to apply such updates:
      --     the merge would only ever insert, never update.
      --
      -- loaded_at is assigned once per COPY statement (CURRENT_TIMESTAMP is
      -- statement-scoped in Snowflake), so a load batch shares one value and a
      -- strict > either takes a whole new batch or nothing — never half of one.
      where loaded_at > (select max(loaded_at) from {{ this }})
    {% endif %}
)

select
    -- degenerate dimension (the contract key carried on the fact)
    contract_id,

    -- foreign keys to the dimensions
    {{ dbt_utils.generate_surrogate_key(['supplier_name', 'supplier_abn']) }} as supplier_key,
    {{ dbt_utils.generate_surrogate_key(['agency_name', 'agency_abn']) }}     as agency_key,
    {{ dbt_utils.generate_surrogate_key(['category_name', 'category_unspsc']) }} as category_key,
    cast(to_char(publish_date, 'YYYYMMDD') as integer)                        as publish_date_key,

    -- measures
    contract_value,
    duration_days,

    -- attributes
    procurement_method,
    publish_date,
    contract_start_date,
    contract_end_date,

    -- audit: carried so the incremental predicate above has a watermark to read
    loaded_at
from contracts
